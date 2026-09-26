# shellcheck shell=bash disable=SC2034 # its variables are used by setup.sh and the other libs
# A new metalgo node on a fresh Ubuntu 24.04 server: its own system user, the
# pinned metalgo, a JSON config file, a hardened systemd unit, a firewall,
# automatic security updates and (optionally) key-only SSH. Sourced by
# setup.sh; not run on its own.

# --- Where a node set up by metalgo-setup lives ------------------------------------
FRESH_UNIT=metalgo
FRESH_USER=metalgo
FRESH_DATA=/var/lib/metalgo                   # data dir; the staking keys are in staking/
FRESH_OPT=/opt/metalgo
FRESH_BIN=$FRESH_OPT/$METALGO_VERSION/metalgo  # root-owned: the service can't change what it runs
FRESH_PLUGINS=$FRESH_OPT/plugins
FRESH_CONF_DIR=/etc/metalgo
FRESH_CONFIG=$FRESH_CONF_DIR/config.json
FRESH_CHAIN_CONFIGS=$FRESH_DATA/configs/chains
# metalgo's working directory, which its plugins inherit: kept empty, never
# the data dir (see workdir_guard in lib/chains.sh).
FRESH_WORKDIR=$FRESH_DATA/workdir
FRESH_HTTP_PORT=9650   # localhost only
FRESH_STAKING_PORT=9651  # public: peers connect here

# Sets the detect.sh variables for the node this file sets up, so the chain
# steps work on it before its unit exists (and in a dry run).
fresh_layout() {
  UNIT_NAME=$FRESH_UNIT UNIT_USER=$FRESH_USER UNIT_GROUP=$FRESH_USER UNIT_MANAGED=1
  UNIT_EXEC_FILE=/etc/systemd/system/$FRESH_UNIT.service UNIT_EXEC_ARGV0=0 UNIT_KILLMODE=mixed
  UNIT_WORKDIR=$FRESH_WORKDIR REL_PATHS=0
  NODE_BIN=$FRESH_BIN DATA_DIR=$FRESH_DATA PLUGIN_DIR=$FRESH_PLUGINS CHAIN_CONFIG_DIR=$FRESH_CHAIN_CONFIGS
  CFG_FILE=$FRESH_CONFIG CFG_TYPE=json CFG_SRC=file NETWORK=mainnet
  NODE_API=http://127.0.0.1:$FRESH_HTTP_PORT CURL_TLS=()
  TRACK_SRC=config
  TRACKED=()
  if [[ -r $FRESH_CONFIG ]]; then
    local s
    for s in $(jq -r '."track-subnets" // "" | gsub(","; " ")' "$FRESH_CONFIG" 2>/dev/null); do TRACKED+=("$s"); done
  fi
}

# --- Checks --------------------------------------------------------------------------
fresh_preflight() {
  local os_id='' os_version=''
  if [[ -r /etc/os-release ]]; then
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  fi
  if [[ $os_id != ubuntu || $os_version != 24.04 ]]; then
    ((DRY_RUN)) || die "a fresh install supports Ubuntu 24.04 only (this is ${os_id:-unknown} ${os_version:-})"
    warn "this is ${os_id:-unknown} ${os_version:-}, not Ubuntu 24.04"
  fi
  if [[ $(uname -m) != x86_64 ]]; then
    ((DRY_RUN)) || die "a fresh install supports x86_64 only (the pinned downloads are linux-amd64)"
    warn "this is $(uname -m), not x86_64"
  fi
  if ! ((UNIT_MANAGED_BEFORE)) && command -v ss >/dev/null; then
    local p
    for p in "$FRESH_HTTP_PORT" "$FRESH_STAKING_PORT"; do
      if ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then
        die "something already listens on port $p; is another node running here? (sudo ss -ltnp 'sport = :$p')"
      fi
    done
  fi
}

fresh_packages() {
  log "System packages"
  local pkgs=(ca-certificates curl jq openssl perl ufw unattended-upgrades)
  ((${#CHAINS[@]} || FROM_SOURCE)) && pkgs+=(git build-essential)
  # A clock in sync matters to consensus. Keep chrony if it is there.
  dpkg -s chrony >/dev/null 2>&1 || pkgs+=(systemd-timesyncd)
  apt_install "${pkgs[@]}"
}

# --- metalgo ----------------------------------------------------------------------------
METALGO_CHANGED=0
fresh_metalgo() {
  run install -d -m 0755 -o root -g root "$FRESH_OPT" "$FRESH_OPT/$METALGO_VERSION" "$FRESH_PLUGINS"
  if ((TEST_ONLY)); then
    [[ -x $FRESH_BIN ]] || METALGO_CHANGED=1
    write_file "$FRESH_BIN" 0755 root:root <<EOF
#!/bin/sh
# metalgo-setup TEST STUB: not a real metalgo
[ "\$1" = --version ] && echo "metalgo/${METALGO_VERSION#v} [database=v1.4.5, rpcchainvm=$METALGO_RPCCHAINVM, commit=$METALGO_COMMIT, go=$GO_VERSION]" && exit 0
exit 1
EOF
    return 0
  fi
  if [[ -x $FRESH_BIN ]] && [[ $(metalgo_version "$FRESH_BIN") == *"rpcchainvm=$METALGO_RPCCHAINVM"* ]]; then
    ok "metalgo $METALGO_VERSION already in $FRESH_BIN"
    return 0
  fi
  if ((FROM_SOURCE)); then
    log "metalgo $METALGO_VERSION from source (commit $METALGO_COMMIT)"
    build_tools
    local src=$BUILD_HOME/src/metalgo
    checkout_pinned "$src" "$METALGO_REPO" "$METALGO_VERSION" "$METALGO_COMMIT"
    build_in "$src" ./scripts/build.sh
    run install -m 0755 -o root -g root "$src/build/metalgo" "$FRESH_BIN.new"
  else
    log "metalgo $METALGO_VERSION (official release, SHA-256 pinned)"
    run install -d -m 0700 -o root -g root "$DL_DIR"
    local tgz=$DL_DIR/metalgo-$METALGO_VERSION.tgz
    run curl -fsSLo "$tgz" "$METALGO_TARBALL_URL"
    verify_sha256 "$tgz" "$METALGO_TARBALL_SHA256"
    run rm -rf "${DL_DIR:?}/$METALGO_TARBALL_DIR"
    run tar -C "$DL_DIR" -xzf "$tgz"
    run install -m 0755 -o root -g root "$DL_DIR/$METALGO_TARBALL_DIR/metalgo" "$FRESH_BIN.new"
    run rm -rf "${DL_DIR:?}/$METALGO_TARBALL_DIR" "$tgz"
  fi
  if ! ((DRY_RUN)); then
    local v
    v=$(metalgo_version "$FRESH_BIN.new")
    [[ $v == "metalgo/${METALGO_VERSION#v} "* && $v == *"rpcchainvm=$METALGO_RPCCHAINVM,"* ]] ||
      { rm -f "$FRESH_BIN.new"; die "the downloaded metalgo reports '$v', not ${METALGO_VERSION#v} with rpcchainvm=$METALGO_RPCCHAINVM"; }
    if [[ $v == *commit=* && $v != *"commit=$METALGO_COMMIT"* ]]; then
      rm -f "$FRESH_BIN.new"
      die "the downloaded metalgo reports '$v', not commit $METALGO_COMMIT"
    fi
    ok "$v"
  fi
  run mv -f "$FRESH_BIN.new" "$FRESH_BIN"
  METALGO_CHANGED=1
}

# --- The node's user, directories and config ----------------------------------------------
fresh_user_and_dirs() {
  log "Service user and directories"
  ensure_user "$FRESH_USER" "$FRESH_DATA"
  run install -d -m 0750 -o "$FRESH_USER" -g "$FRESH_USER" "$FRESH_DATA" "$FRESH_DATA/logs" "$FRESH_DATA/configs" "$FRESH_DATA/l1" "$FRESH_WORKDIR"
  run install -d -m 0750 -o "$FRESH_USER" -g "$FRESH_USER" "$FRESH_CHAIN_CONFIGS"
  run install -d -m 0755 -o root -g root "$FRESH_CONF_DIR"
}

PUBLIC_IP=''
fresh_public_ip() {
  local saved=''
  [[ -r $FRESH_CONFIG ]] && saved=$(jq -r '."public-ip" // empty' "$FRESH_CONFIG" 2>/dev/null || true)
  PUBLIC_IP=${PUBLIC_IP_ARG:-$saved}
  if [[ -n $PUBLIC_IP ]]; then
    :
  elif ((TEST_ONLY)); then
    PUBLIC_IP=192.0.2.10 # TEST-NET-1: documentation only, never routed
  elif ((DRY_RUN)); then
    printf '    + curl -fsS4 -m 10 https://ifconfig.me   (detects the public IP)\n'
    PUBLIC_IP='<public-ip>'
    return 0
  else
    PUBLIC_IP=$(curl -fsS4 -m 10 https://ifconfig.me || curl -fsS4 -m 10 https://api.ipify.org || true)
  fi
  [[ $PUBLIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "could not tell this server's public IPv4 ('$PUBLIC_IP'); pass --public-ip"
  info "public IP: $PUBLIC_IP"
}

# fresh_config TRACK_SUBNETS: the node's config file. metalgo-setup owns the
# keys below; any other key an operator adds is kept.
fresh_config() {
  log "metalgo config ($FRESH_CONFIG)"
  local tracked=$1 partial=false mode=$MODE track_line=''
  [[ -n $tracked ]] && track_line=$',\n  "track-subnets": "'"$tracked"'"'
  if [[ -z $mode ]]; then
    mode=l1-only
    [[ -r $FRESH_CONFIG ]] && ! jq -e '."partial-sync-primary-network" == true' "$FRESH_CONFIG" >/dev/null 2>&1 && mode=full
  fi
  MODE=$mode
  [[ $MODE == l1-only ]] && partial=true
  local managed
  managed=$(
    cat <<EOF
{
  "network-id": "mainnet",
  "data-dir": "$FRESH_DATA",
  "log-dir": "$FRESH_DATA/logs",
  "plugin-dir": "$FRESH_PLUGINS",
  "chain-config-dir": "$FRESH_CHAIN_CONFIGS",
  "http-host": "127.0.0.1",
  "http-port": $FRESH_HTTP_PORT,
  "staking-port": $FRESH_STAKING_PORT,
  "public-ip": "$PUBLIC_IP",
  "partial-sync-primary-network": $partial$track_line
}
EOF
  )
  if [[ -r $FRESH_CONFIG ]]; then
    local merged
    merged=$(jq --argjson m "$managed" '. + $m | if $m."track-subnets" then . else del(."track-subnets") end' "$FRESH_CONFIG") &&
      [[ -n $merged ]] || die "$FRESH_CONFIG isn't valid JSON; fix or move it, then re-run"
    write_file "$FRESH_CONFIG" 0644 root:root <<<"$merged"
  else
    write_file "$FRESH_CONFIG" 0644 root:root <<<"$managed"
  fi
  ((FILE_CHANGED)) && METALGO_CHANGED=1
  return 0
}

# Sandboxing: everything read-only (ProtectSystem=strict) or hidden, except
# the data dir.
fresh_unit() {
  log "systemd service ($FRESH_UNIT.service)"
  local desc='Metal Blockchain node (P-Chain only, for the L1s)'
  [[ $MODE == full ]] && desc='Metal Blockchain node (full primary network)'
  write_file "/etc/systemd/system/$FRESH_UNIT.service" 0644 root:root <<EOF
# $MANAGED_MARK; re-run it rather than editing this.
# Settings are in $FRESH_CONFIG.
[Unit]
Description=$desc
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$FRESH_USER
Group=$FRESH_USER
Environment=HOME=$FRESH_DATA
# Its own empty directory, never the data dir: plugins inherit it, and the
# L1 plugins' embedded btcd (before its fix) deleted ./db at start.
WorkingDirectory=$FRESH_WORKDIR
ExecStart=$FRESH_BIN --config-file=$FRESH_CONFIG
Restart=on-failure
RestartSec=10
# SIGTERM to metalgo only: it shuts each chain down in order, and each L1
# plugin closes its database. Sent to the whole unit at once, a plugin could
# die first and lose its newest blocks.
KillMode=mixed
TimeoutStopSec=120
LimitNOFILE=65536

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RemoveIPC=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
UMask=0077
ReadWritePaths=$FRESH_DATA
# The plugins talk to metalgo over local sockets; NETLINK lets Go list
# network interfaces.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
  ((FILE_CHANGED)) && METALGO_CHANGED=1 UNIT_FILES_CHANGED=1
  return 0
}

# --- The server ---------------------------------------------------------------------------
ssh_ports() {
  local ports=''
  command -v sshd >/dev/null 2>&1 && ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u | tr '\n' ' ')
  printf '%s' "${ports:-22}"
}

fresh_firewall() {
  log "Firewall (ufw): SSH and the staking port in; the API stays on localhost"
  local p
  # SSH first, so turning the firewall on can't lock anyone out.
  for p in $(ssh_ports); do run ufw allow "$p/tcp" comment 'SSH'; done
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "$FRESH_STAKING_PORT/tcp" comment 'Metal peers (staking port)'
  run ufw --force enable
}

fresh_auto_updates() {
  log "Automatic security updates"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root:root <<EOF
// $MANAGED_MARK.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

fresh_ssh() {
  ((HARDEN_SSH)) || { info "SSH left as it is (--harden-ssh turns password logins off)"; return 0; }
  command -v sshd >/dev/null 2>&1 || { info "no SSH server here; nothing to harden"; return 0; }
  log "SSH: key logins only"
  # Only turn passwords off if someone can already log in with a key.
  local f has_key=0 conf=/etc/ssh/sshd_config.d/10-metalgo-setup.conf
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s $f ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" && has_key=1
  done
  if ((!has_key)); then
    warn "no SSH key in any authorized_keys: leaving password logins ON so you aren't locked out. Add a key and re-run."
    return 0
  fi
  write_file "$conf" 0644 root:root <<EOF
# $MANAGED_MARK: key logins only.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ((FILE_CHANGED)) && ! ((DRY_RUN)); then
    if ! sshd -t; then
      rm -f "$conf"
      die "sshd rejected the new settings; removed them, SSH unchanged"
    fi
    systemctl try-reload-or-restart ssh.service
  fi
}

# --- After the start ----------------------------------------------------------------------
fresh_identity() {
  local staking=$FRESH_DATA/staking
  echo
  log "This node's identity"
  if [[ -n ${NODE_ID:-} ]]; then
    info "NodeID: $NODE_ID"
  else
    info "NodeID: not known yet (the API isn't up); see it with: sudo ./setup.sh --status"
  fi
  cat <<EOF
    Its staking key and certificate (made by metalgo on first start):
      $staking/staker.key    TLS key: this is what makes the NodeID
      $staking/staker.crt    TLS certificate
      $staking/signer.key    BLS key, for signing as a validator
    ${BOLD}Back these three files up offline now${RESET} (e.g. to an encrypted USB drive
    you keep somewhere safe). Without them a rebuilt server gets a new NodeID,
    and anyone who copies them can pose as this node. metalgo-setup never
    reads, prints or copies them.
EOF
}
