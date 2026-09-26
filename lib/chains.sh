# shellcheck shell=bash disable=SC2034 # its variables are used by setup.sh and the other libs
# Adding and removing the L1s on a metalgo node that detect.sh has read
# (DATA_DIR, PLUGIN_DIR, CHAIN_CONFIG_DIR, TRACKED, UNIT_*). Sourced by
# setup.sh; not run on its own.

NODE_CHANGED=0 UNIT_FILES_CHANGED=0

# --- Build tools ------------------------------------------------------------------
ensure_user() {
  local name=$1 home=$2
  id "$name" >/dev/null 2>&1 && return 0
  run useradd --system --user-group --home-dir "$home" --no-create-home --shell /usr/sbin/nologin "$name"
}

build_tools() {
  log "Build user and Go $GO_VERSION (SHA-256 pinned)"
  ensure_user "$BUILD_USER" "$BUILD_HOME"
  run install -d -m 0750 -o "$BUILD_USER" -g "$BUILD_USER" "$BUILD_HOME" "$BUILD_HOME/src" "$BUILD_HOME/out"
  run install -d -m 0755 -o root -g root "$TOOLS_DIR"
  run install -d -m 0700 -o root -g root "$DL_DIR" "$STATE_DIR" "$STATE_DIR/built"
  ((TEST_ONLY)) && return 0
  if grep -q "go$GO_VERSION " <<<"$("$GO_ROOT/bin/go" version 2>/dev/null)"; then
    info "Go $GO_VERSION already in $GO_ROOT"
    return 0
  fi
  local tgz=$DL_DIR/go$GO_VERSION.tgz
  run curl -fsSLo "$tgz" "$GO_URL"
  verify_sha256 "$tgz" "$GO_SHA256"
  run rm -rf "$DL_DIR/go" "$GO_ROOT"
  run tar -C "$DL_DIR" -xzf "$tgz"
  run chown -R root:root "$DL_DIR/go"
  run mv "$DL_DIR/go" "$GO_ROOT"
  run rm -f "$tgz"
}

# --- Plugins ----------------------------------------------------------------------
# The plugin file's SHA-256, or empty.
file_sha() { [[ -f $1 ]] && sha256sum "$1" | cut -d' ' -f1; }

# install_plugin CHAIN: builds the plugin at its pin as the build user, checks
# the VM ID, and puts it in the plugin directory atomically, if different.
install_plugin() {
  local c=$1 title vmid repo branch commit pkg dest stamp src out
  title=$(chain_var "$c" TITLE) vmid=$(chain_var "$c" VM_ID) repo=$(chain_var "$c" REPO)
  branch=$(chain_var "$c" BRANCH) commit=$(chain_var "$c" COMMIT) pkg=$(chain_var "$c" PLUGIN_PKG)
  dest=$PLUGIN_DIR/$vmid stamp=$STATE_DIR/built/$c
  # Built at this pin before, and the file is still what was built: done.
  if [[ -f $stamp && -f $dest ]] && [[ "$(cat "$stamp")" == "$commit $(file_sha "$dest")" ]]; then
    ok "$title plugin: already the pinned build ($commit)"
    return 0
  fi
  log "$title plugin from source ($repo at $commit)"
  src=$BUILD_HOME/src/$c out=$BUILD_HOME/out/$c
  if ((TEST_ONLY)); then
    # A stand-in whose content names the pin, so a new pin is a change.
    run install -d -m 0750 -o "$BUILD_USER" -g "$BUILD_USER" "$out"
    printf '#!/bin/sh\n# metalgo-setup TEST STUB for %s at %s: not a real plugin\nexit 1\n' "$c" "$commit" >"$out/plugin.test"
    chown "$BUILD_USER:$BUILD_USER" "$out/plugin.test"
    mv -f "$out/plugin.test" "$out/plugin"
  else
    checkout_pinned "$src" "$repo" "$branch" "$commit"
    as_build mkdir -p "$out"
    # The plugin's file name must be the VM ID the L1 was created with.
    if ((DRY_RUN)); then
      build_in "$src" go run ./scripts/vm-id-generator.go
      info "(stops unless that prints $vmid)"
    else
      local got
      # shellcheck disable=SC2016 # $1 belongs to the inner shell
      got=$(build_env bash -c 'cd "$1" && go run ./scripts/vm-id-generator.go' _ "$src" | tail -1)
      [[ $got == "$vmid" ]] || die "$repo at $commit builds VM $got, but the $title L1 runs $vmid; not installing it"
      ok "VM ID $got"
    fi
    build_in "$src" go build -o "$out/plugin" "$pkg"
  fi
  if ! ((DRY_RUN)) && [[ -f $dest ]] && cmp -s "$out/plugin" "$dest"; then
    ok "$title plugin in $PLUGIN_DIR is already this build"
  else
    if [[ ! -d $PLUGIN_DIR ]]; then
      run install -d -m 0755 -o root -g root "$PLUGIN_DIR"
    fi
    backup "$dest"
    # Staged beside the plugin directory, not in it (metalgo treats every
    # file there as a VM), on the same filesystem, so the mv is atomic and
    # the node never sees half a plugin.
    local stage
    stage=$(dirname "$PLUGIN_DIR")/.metalgo-setup-$vmid.new
    run install -m 0755 -o root -g root "$out/plugin" "$stage"
    run mv -f "$stage" "$dest"
    NODE_CHANGED=1
    ok "installed $dest"
  fi
  if ! ((DRY_RUN)); then
    printf '%s %s\n' "$commit" "$(file_sha "$dest")" >"$stamp"
  fi
}

# --- Chain configs ------------------------------------------------------------------
# ensure_node_dir DIR MODE: makes DIR and any missing parents, owned by the
# node's user.
ensure_node_dir() {
  local dir=$1 mode=$2 missing=() d=$1
  while [[ ! -d $d && $d != / ]]; do
    missing=("$d" ${missing[@]+"${missing[@]}"})
    d=$(dirname "$d")
  done
  for d in ${missing[@]+"${missing[@]}"}; do
    run install -d -m "$mode" -o "$UNIT_USER" -g "$UNIT_GROUP" "$d"
  done
}

# The directories an L1's own database and logs go in: under the metalgo data
# dir, which the service can already write (also under ProtectSystem=strict).
chain_state_dir() { printf '%s/l1/%s' "$DATA_DIR" "$1"; }

# existing_chain_config CHAIN: the chain's config file, if there is one.
# metalgo reads <chain-config-dir>/<chain ID>/config.* (any extension).
existing_chain_config() {
  local f
  for f in "$CHAIN_CONFIG_DIR/$(chain_var "$1" CHAIN_ID)"/config.*; do
    [[ -f $f ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

chain_config() {
  local c=$1 title id dir cfg state existing pass
  title=$(chain_var "$c" TITLE) id=$(chain_var "$c" CHAIN_ID)
  dir=$CHAIN_CONFIG_DIR/$id cfg=$dir/config.json state=$(chain_state_dir "$c")
  if existing=$(existing_chain_config "$c"); then
    ok "$title chain config: keeping $existing"
    if ((RPC)) && ! jq -e '.rpcUser and .rpcPass' "$existing" >/dev/null 2>&1; then
      warn "$existing has no rpcUser/rpcPass, and metalgo-setup doesn't change an existing chain config: add them yourself for the $title JSON-RPC"
    fi
    return 0
  fi
  log "$title chain config ($cfg)"
  ensure_node_dir "$CHAIN_CONFIG_DIR" 0750
  run install -d -m 0700 -o "$UNIT_USER" -g "$UNIT_GROUP" "$dir"
  ensure_node_dir "$state" 0700
  run install -d -m 0700 -o "$UNIT_USER" -g "$UNIT_GROUP" "$state/data" "$state/logs"
  # Written directly, not with jq: every value is plain text (fixed paths, a
  # hex password), with nothing to escape.
  if ((RPC)); then
    pass=$(new_secret)
    SECRET_CONTENT=1
    write_file "$cfg" 0600 "$UNIT_USER:$UNIT_GROUP" <<EOF
{
  "rpcUser": "$c",
  "rpcPass": "$pass",
  "txIndex": true,
  "addrIndex": true,
  "dataDir": "$state/data",
  "logDir": "$state/logs"
}
EOF
    SECRET_CONTENT=0
    info "JSON-RPC on this node: $NODE_API/ext/bc/$id/rpc (user $c; password in $cfg)"
  else
    write_file "$cfg" 0600 "$UNIT_USER:$UNIT_GROUP" <<EOF
{
  "dataDir": "$state/data",
  "logDir": "$state/logs"
}
EOF
  fi
  NODE_CHANGED=1
}

# --- track-subnets ------------------------------------------------------------------
# edit_track_flag NEW < TEXT: TEXT (a unit file or an ExecStart value) with its
# --track-subnets flag set to NEW (removed if NEW is empty), or the flag
# added after the binary. Only ExecStart lines change.
edit_track_flag() {
  NEW_SUBNETS=$1 perl -e '
    my $text = do { local $/; <STDIN> };
    my ($new, $add) = ($ENV{NEW_SUBNETS}, $ENV{ADD_FLAG});
    # Either a whole unit file, or just an ExecStart value.
    my $bare = $text !~ /^\s*ExecStart\s*=/m;
    my ($in, $hits, $execs) = (0, 0, 0);
    my @lines = split /(?<=\n)/, $text;
    for my $l (@lines) {
      my $start = $bare ? ($execs == 0) : ($l =~ /^\s*ExecStart\s*=\s*\S/);
      if ($start) { $in = 1; $execs++; }
      if ($in && $l !~ /^\s*[#;]/) {
        if ($add) {
          if ($start) {
            my $re = $bare ? qr/^(\s*\S+)/ : qr/^(\s*ExecStart\s*=\s*\S+)/;
            $l =~ s/$re/$1 --track-subnets=$new/ and $hits++;
          }
        } elsif ($new eq "") {
          $hits += ($l =~ s/[ \t]+--track-subnets(?:=|[ \t]+)(["\x27]?)[^\s"\x27\\]*\1//g);
        } else {
          $hits += ($l =~ s/(--track-subnets(?:=|[ \t]+))(["\x27]?)[^\s"\x27\\]*\2/$1$2$new$2/g);
        }
      }
      # A trailing backslash continues the ExecStart line.
      $in = 0 unless $bare || $l =~ /\\\n?\z/;
    }
    die "$execs ExecStart lines; expected one\n" if $add && $execs != 1;
    die "found --track-subnets $hits times; expected once\n" unless $hits == 1;
    print @lines;
  '
}

# write_tracked LIST: sets the node's track-subnets to LIST (comma
# separated), wherever metalgo reads it from.
write_tracked() {
  local new=$1 where=$TRACK_SRC
  if [[ $where == default ]]; then
    # Not set anywhere: into the JSON config file if there is one, else a flag.
    if [[ $CFG_SRC == file && $CFG_TYPE == json ]]; then where=config; else where=flag-add; fi
  fi
  case $where in
    config)
      [[ $CFG_TYPE == json ]] ||
        die "track-subnets is set in $CFG_FILE ($CFG_TYPE), which metalgo-setup doesn't edit. Set it yourself: track-subnets: \"$new\", then re-run with --no-restart ... and restart $UNIT_NAME"
      local mode owner
      mode=$(stat -c '%a' "$CFG_FILE") owner=$(stat -c '%U:%G' "$CFG_FILE")
      log "track-subnets in $CFG_FILE"
      write_file "$CFG_FILE" "0$mode" "$owner" < <(
        jq --arg new "$new" '
          ([keys[] | select(ascii_downcase == "track-subnets")] | last // "track-subnets") as $k
          | if $new == "" then del(.[$k]) else .[$k] = $new end' "$CFG_FILE"
      )
      ;;
    flag | flag-add)
      local file=$UNIT_EXEC_FILE add=0
      [[ $where == flag-add ]] && add=1
      ((add && UNIT_EXEC_ARGV0)) && die "$UNIT_NAME.service's ExecStart sets argv[0] (@); add --track-subnets=$new to it yourself"
      if [[ $file == /etc/* ]]; then
        log "track-subnets in $file"
        local mode owner
        mode=$(stat -c '%a' "$file") owner=$(stat -c '%U:%G' "$file")
        local edited
        edited=$(
          ADD_FLAG=$add edit_track_flag "$new" <"$file" || exit 1
          printf x
        ) || die "can't edit --track-subnets in $file"
        write_file "$file" "0$mode" "$owner" < <(printf '%s' "${edited%x}")
      else
        # A packaged unit: override its ExecStart with a drop-in instead.
        local dropin=/etc/systemd/system/$UNIT_NAME.service.d/20-metalgo-setup-exec.conf exec
        log "track-subnets: $file is packaged, so overriding ExecStart in $dropin"
        exec=$(ADD_FLAG=$add edit_track_flag "$new" <<<"$UNIT_EXEC") || die "can't edit --track-subnets in $UNIT_NAME.service's ExecStart"
        run install -d -m 0755 -o root -g root "$(dirname "$dropin")"
        write_file "$dropin" 0644 root:root <<EOF
# $MANAGED_MARK: $UNIT_NAME's ExecStart from $file, with the
# L1 subnets it tracks. Re-run metalgo-setup to change them.
[Service]
ExecStart=
ExecStart=$exec
EOF
      fi
      ((FILE_CHANGED)) && UNIT_FILES_CHANGED=1
      ;;
    env)
      die "track-subnets comes from AVAGO_TRACK_SUBNETS in $UNIT_NAME.service's environment, which metalgo-setup doesn't edit. Set AVAGO_TRACK_SUBNETS=$new yourself, then re-run"
      ;;
    content)
      die "track-subnets comes from --config-file-content (base64), which metalgo-setup doesn't edit. Set track-subnets to \"$new\" there yourself, then re-run"
      ;;
  esac
  NODE_CHANGED=1
}

# set_tracked SUBNET...: the node tracks exactly these (plus nothing else).
set_tracked() {
  local want=("$@") new
  new=$(
    IFS=,
    printf '%s' "${want[*]:-}"
  )
  local old
  old=$(
    IFS=,
    printf '%s' "${TRACKED[*]:-}"
  )
  if [[ $new == "$old" ]]; then
    ok "track-subnets unchanged: ${old:-none}"
    return 0
  fi
  info "track-subnets: ${old:-none}"
  info "          ->   ${new:-none}"
  write_tracked "$new"
  if ! ((DRY_RUN)); then
    # Read it all back the way metalgo will, and check. (systemctl cat sees a
    # new drop-in only after a reload; reloading restarts nothing.)
    ((UNIT_FILES_CHANGED)) && systemctl daemon-reload
    detect_existing "$UNIT_NAME" >/dev/null
    local got
    got=$(
      IFS=,
      printf '%s' "${TRACKED[*]:-}"
    )
    [[ $got == "$new" ]] || die "after the change, $UNIT_NAME would track '$got', not '$new'; the files changed are backed up in $BACKUP_DIR"
  else
    TRACKED=(${want[@]+"${want[@]}"})
  fi
}

# --- The unit's stop behaviour --------------------------------------------------------
# metalgo must get SIGTERM first and shut each chain down in order, so each
# L1 plugin closes its database. With systemd's default KillMode (the whole
# control group at once), a plugin can die first and lose its newest blocks.
killmode_dropin() {
  [[ ${UNIT_KILLMODE,,} == mixed ]] && return 0
  local dropin=/etc/systemd/system/$UNIT_NAME.service.d/10-metalgo-setup-stop.conf timeout=''
  log "Stop behaviour for the L1 plugins ($dropin)"
  info "$UNIT_NAME.service has KillMode=${UNIT_KILLMODE:-control-group (the default)}; plugins need KillMode=mixed"
  [[ -z $UNIT_TIMEOUT_STOP ]] && timeout=$'\nTimeoutStopSec=120'
  run install -d -m 0755 -o root -g root "$(dirname "$dropin")"
  write_file "$dropin" 0644 root:root <<EOF
# $MANAGED_MARK. SIGTERM goes to metalgo only, which shuts each
# chain down in order so every L1 plugin closes its database; sent to all
# processes at once, a plugin could die first and lose its newest blocks.
[Service]
KillMode=mixed$timeout
EOF
  ((FILE_CHANGED)) && UNIT_FILES_CHANGED=1 NODE_CHANGED=1
  return 0
}

# --- Removing -----------------------------------------------------------------------
remove_chain() {
  local c=$1 title id vmid cfg state data='' logs=''
  title=$(chain_var "$c" TITLE) id=$(chain_var "$c" CHAIN_ID) vmid=$(chain_var "$c" VM_ID)
  log "Removing $title"
  if [[ -n ${NODE_ID:-} && $(validates "$NODE_ID" "$(chain_var "$c" SUBNET_ID)") == true ]] && ! ((FORCE)); then
    die "$NODE_ID is a validator of the $title L1; removing the chain would stop it validating. Not removing (--force overrides)."
  fi
  if [[ -f $PLUGIN_DIR/$vmid ]]; then
    remove_path "$PLUGIN_DIR/$vmid"
    NODE_CHANGED=1
  fi
  run rm -f "$STATE_DIR/built/$c"
  cfg=$(existing_chain_config "$c" || true)
  if [[ -n $cfg ]]; then
    data=$(jq -r '.dataDir // empty' "$cfg" 2>/dev/null || true)
    logs=$(jq -r '.logDir // empty' "$cfg" 2>/dev/null || true)
  fi
  state=$(chain_state_dir "$c")
  if ((PURGE)); then
    local p
    for p in "$data" "$logs" "$state" "$DATA_DIR/chainData/$id" "$CHAIN_CONFIG_DIR/$id"; do
      [[ -n $p && -e $p ]] || continue
      # Only ever delete inside the node's own directories.
      if [[ $p == "$DATA_DIR"/* || $p == "$CHAIN_CONFIG_DIR"/* ]]; then
        run rm -rf -- "$p"
        info "deleted $p"
      else
        warn "not deleting $p: outside $DATA_DIR"
      fi
    done
  else
    info "kept its data and config (--purge deletes them): ${cfg:-no config}${data:+, $data}${logs:+, $logs}"
  fi
}

# --- Waiting and reporting -----------------------------------------------------------
# rpc_height URL [CONFIG]: getblockcount, authenticated with the chain
# config's rpcUser/rpcPass (fed to curl on stdin, never on its command line).
rpc_height() {
  local url=$1 auth=$2
  printf 'user = "%s"\n' "$auth" |
    curl -s -m 10 -K - ${CURL_TLS[@]+"${CURL_TLS[@]}"} -H 'content-type: application/json' \
      -d '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$url" 2>/dev/null |
    jq -r '.result // empty' 2>/dev/null || true
}

local_height() {
  local c=$1 id cfg auth=''
  id=$(chain_var "$c" CHAIN_ID)
  cfg=$(existing_chain_config "$c" || true)
  if [[ -n $cfg ]]; then
    auth=$(jq -r 'if .rpcUser and .rpcPass then "\(.rpcUser):\(.rpcPass)" else empty end' "$cfg" 2>/dev/null || true)
  fi
  if [[ -n $auth ]]; then
    rpc_height "$NODE_API/ext/bc/$id/rpc" "$auth"
    return
  fi
  # No local JSON-RPC: metalgo's own count of accepted blocks.
  curl -s -m 10 ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$NODE_API/ext/metrics" 2>/dev/null |
    awk -v id="$id" '$1 ~ /^metal_snowman_last_accepted_height\{/ && index($1, "chain=\"" id "\"") {print int($2); exit}'
}

report_heights() {
  local c local_h public_h title
  log "Heights: this node vs the public RPC"
  for c in "$@"; do
    title=$(chain_var "$c" TITLE)
    local_h=$(local_height "$c")
    public_h=$(rpc_height "$(chain_var "$c" PUBLIC_RPC)" "$(chain_var "$c" PUBLIC_RPC_AUTH)")
    printf '    %-11s local %-8s public %-8s %s\n' "$title" "${local_h:-?}" "${public_h:-?}" \
      "$(if [[ -n $local_h && -n $public_h ]] && ((local_h + 2 >= public_h)); then echo "${GREEN}in sync${RESET}"; elif [[ -n $local_h && -n $public_h ]]; then echo "$((public_h - local_h)) behind"; fi)"
  done
}

# wait_api SECONDS: until the node's API answers.
wait_api() {
  local deadline=$((SECONDS + $1))
  while ((SECONDS < deadline)); do
    NODE_ID=$(node_id)
    [[ -n $NODE_ID ]] && return 0
    sleep 3
  done
  return 1
}

# wait_bootstrapped SECONDS CHAIN...: until the P-Chain and each L1 have
# bootstrapped; prints progress. Returns 1 on timeout.
wait_bootstrapped() {
  local secs=$1 deadline c id title state next_note=0 pending
  shift
  deadline=$((SECONDS + secs))
  log "Waiting for the P-Chain and each L1 to bootstrap (up to $((secs / 60)) min)"
  while true; do
    pending=()
    [[ $(is_bootstrapped P) == true ]] || pending+=(P-Chain)
    for c in "$@"; do
      id=$(chain_var "$c" CHAIN_ID)
      [[ $(is_bootstrapped "$id") == true ]] || pending+=("$(chain_var "$c" TITLE)")
    done
    if ((${#pending[@]} == 0)); then
      ok "P-Chain bootstrapped"
      for c in "$@"; do ok "$(chain_var "$c" TITLE) bootstrapped ($(chain_var "$c" CHAIN_ID))"; done
      return 0
    fi
    if ((SECONDS >= deadline)); then
      warn "still bootstrapping after $((secs / 60)) min: ${pending[*]}. That's normal on a first sync; check again later with: sudo ./setup.sh --status"
      return 1
    fi
    if ((SECONDS >= next_note)); then
      info "still bootstrapping: ${pending[*]}"
      next_note=$((SECONDS + 60))
    fi
    sleep 5
  done
}
