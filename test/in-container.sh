#!/usr/bin/env bash
# One test scenario, inside a throwaway container started by test/run.sh,
# with the repository at /src (read-only). TEST MODE only: never run this on
# a real server.
#
#   in-container.sh SCENARIO
# shellcheck disable=SC2016 # single-quoted jq programs and inner shells
set -euo pipefail
[[ -f /.dockerenv ]] || { echo "refusing: this only runs inside a test container" >&2; exit 1; }
SCENARIO=${1:?scenario}
# shellcheck source=../lib/pins.sh
source /src/lib/pins.sh
export METALGO_SETUP_TEST_ONLY=1
OUT=/tmp/outputs.log
: >"$OUT"
SYSTEMCTL_LOG=/var/log/fake-systemctl.log
UFW_LOG=/var/log/fake-ufw.log

step() { printf '\n=== %s\n' "$*"; }
check() {
  local desc=$1
  shift
  if "$@"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"
    exit 1
  fi
}
owner_mode() { [[ "$(stat -c '%U %a' "$1")" == "$2" ]]; }
has() { grep -q -- "$2" "$1"; }
lacks() { ! grep -q -- "$2" "$1"; }
# setup ARGS...: runs setup.sh, keeping its output for the secrets check.
setup() { /src/setup.sh "$@" 2>&1 | tee -a "$OUT"; return "${PIPESTATUS[0]}"; }
# fails_with TEXT ARGS...: setup.sh exits non-zero and says TEXT.
fails_with() {
  local text=$1 out
  shift
  if out=$("${SETUP:-/src/setup.sh}" "$@" 2>&1); then
    echo "$out"
    return 1
  fi
  grep -qF -- "$text" <<<"$out" || { echo "$out"; return 1; }
}
restarts() { grep -c "systemctl restart $1" "$SYSTEMCTL_LOG" 2>/dev/null || true; }
# Every file (hash) and path (owner, mode, time) that setup.sh could touch.
snapshot() {
  local p paths=()
  for p in /etc/systemd/system /lib/systemd/system /etc/metalgo /etc/node /opt /var/lib /home /etc/apt/apt.conf.d; do
    [[ -e $p ]] && paths+=("$p")
  done
  find "${paths[@]}" \( -path /var/lib/dpkg -o -path /var/lib/apt -o -path /var/lib/systemd -o -path /var/lib/pam -o -path '*/.cache' \) -prune -o -type f -print0 |
    sort -z | xargs -0 -r sha256sum
  find "${paths[@]}" \( -path /var/lib/dpkg -o -path /var/lib/apt -o -path /var/lib/systemd -o -path /var/lib/pam -o -path '*/.cache' \) -prune -o -printf '%p %U %G %m %T@\n' | sort
  getent passwd | sort
}
same_as() {
  local now
  now=$(snapshot)
  [[ $1 == "$now" ]] && return 0
  diff <(echo "$1") <(echo "$now") | head -40 || true
  return 1
}
tracked_in_unit() { grep -o -- '--track-subnets=[^ ]*' "$1" | cut -d= -f2; }
verify_unit() {
  local u=$1 out
  out=$(systemd-analyze verify "$u" 2>&1 || true)
  # Only this unit's own problems count; a container lacks the rest of a
  # booted system (and says so about other units).
  if grep -F "$(basename "$u")" <<<"$out" | grep -vE 'Unit is bound to inactive|Failed to .*(bus|cgroup)' | grep -q .; then
    echo "$out"
    return 1
  fi
}
no_secrets_printed() {
  local f p
  for f in $(find / -xdev -path '*/configs/chains/*' -name config.json 2>/dev/null) \
    $(find / -xdev -path '*/chain-configs/*' -name config.json 2>/dev/null); do
    p=$(jq -r '.rpcPass // empty' "$f")
    [[ -z $p ]] && continue
    if grep -qF -- "$p" "$OUT"; then
      echo "the password in $f appears in setup.sh's output"
      return 1
    fi
  done
}

BTC_SUB=$btcvm_SUBNET_ID LTC_SUB=$ltcvm_SUBNET_ID DOGE_SUB=$dogevm_SUBNET_ID
OTHER_SUB=2oYMBNV4eNHyqk2fjjV5nVQLDbtmNJzq5s3qs3Lo6ftnC6FByM # another L1 the operator tracks (made up)

# A node like the LTCVM server's: flags only, its own user, tracking LTCVM.
make_flags_node() {
  useradd --system --create-home --home-dir /home/ltcvm --shell /usr/sbin/nologin ltcvm
  # Under emulation (Rosetta), running a binary as a user makes ~/.cache:
  # made now, so it doesn't look like a change setup.sh made.
  install -d -o ltcvm -g ltcvm /home/ltcvm/.cache
  install -d -o ltcvm -g ltcvm /home/ltcvm/metalgo/build /opt/ltcvm/node /opt/ltcvm/logs /opt/ltcvm/plugins /opt/ltcvm/chain-configs
  install -m 0755 /usr/local/lib/fake-metalgo /home/ltcvm/metalgo/build/metalgo
  # An LTCVM plugin and chain config from an earlier install.
  printf 'an LTCVM plugin built by someone else\n' >"/opt/ltcvm/plugins/$ltcvm_VM_ID"
  install -d -o ltcvm -g ltcvm -m 0700 "/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID"
  printf '{"rpcUser":"ltcvm","rpcPass":"%s","dataDir":"/opt/ltcvm/chaindata"}\n' "$(openssl rand -hex 24)" \
    >"/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json"
  chown ltcvm:ltcvm "/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json"
  cat >/etc/systemd/system/metal-mainnet.service <<EOF
[Unit]
Description=Metal Blockchain mainnet node (LTCVM L1 validator)
After=network-online.target

[Service]
User=ltcvm
Environment=HOME=/home/ltcvm
WorkingDirectory=/home/ltcvm
ExecStart=/home/ltcvm/metalgo/build/metalgo --network-id=mainnet --partial-sync-primary-network=true --data-dir=/opt/ltcvm/node --log-dir=/opt/ltcvm/logs --plugin-dir=/opt/ltcvm/plugins --chain-config-dir=/opt/ltcvm/chain-configs --http-host=127.0.0.1 --http-port=9660 --staking-port=9661 --track-subnets=$LTC_SUB --public-ip=192.0.2.20
Restart=on-failure
KillMode=mixed
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
  systemctl start metal-mainnet
}

case $SCENARIO in
  fresh-l1-only)
    step "dry run on a fresh server changes nothing"
    before=$(snapshot)
    setup --chains all --rpc --dry-run >/tmp/dry.log
    check "dry run printed the plan" has /tmp/dry.log "+ write /etc/systemd/system/metalgo.service"
    check "dry run would add all three subnets" has /tmp/dry.log "\"track-subnets\": \"$BTC_SUB,$LTC_SUB,$DOGE_SUB\""
    check "dry run hides the RPC password" has /tmp/dry.log "holds a password: not shown"
    check "nothing changed" same_as "$before"
    check "no service touched" test ! -s "$SYSTEMCTL_LOG"

    step "fresh install, l1-only, all three L1s, with RPC"
    setup --chains all --rpc >/tmp/run1.log
    check "user metalgo, no login shell" bash -c "getent passwd metalgo | grep -q ':/usr/sbin/nologin$'"
    check "data dir 750, metalgo's" owner_mode /var/lib/metalgo "metalgo 750"
    cfg=/etc/metalgo/config.json
    check "config: mainnet, P-Chain only, API on localhost" \
      jq -e '."network-id" == "mainnet" and ."partial-sync-primary-network" == true and ."http-host" == "127.0.0.1"' "$cfg"
    check "config: tracks the three subnets" jq -e --arg t "$BTC_SUB,$LTC_SUB,$DOGE_SUB" '."track-subnets" == $t' "$cfg"
    check "config: plugin and chain config dirs" \
      jq -e '."plugin-dir" == "/opt/metalgo/plugins" and ."chain-config-dir" == "/var/lib/metalgo/configs/chains"' "$cfg"
    unit=/etc/systemd/system/metalgo.service
    for want in 'KillMode=mixed' 'TimeoutStopSec=120' 'NoNewPrivileges=yes' 'ProtectSystem=strict' \
      '^ReadWritePaths=/var/lib/metalgo$' '^CapabilityBoundingSet=$' "--config-file=/etc/metalgo/config.json" '^User=metalgo$'; do
      check "unit: $want" has "$unit" "$want"
    done
    check "systemd-analyze verify metalgo.service" verify_unit "$unit"
    check "metalgo binary root-owned" owner_mode "/opt/metalgo/$METALGO_VERSION/metalgo" "root 755"
    for c in $ALL_CHAINS; do
      vm=${c}_VM_ID id=${c}_CHAIN_ID
      check "$c plugin under its VM ID, root-owned" owner_mode "/opt/metalgo/plugins/${!vm}" "root 755"
      ccfg=/var/lib/metalgo/configs/chains/${!id}/config.json
      check "$c chain config 600, metalgo's" owner_mode "$ccfg" "metalgo 600"
      # shellcheck disable=SC2016 # jq variables
      check "$c chain config: RPC user, random password, indexes, data under the data dir" \
        jq -e --arg c "$c" '.rpcUser == $c and (.rpcPass | test("^[0-9a-f]{48}$")) and .txIndex and .addrIndex
          and (.dataDir | startswith("/var/lib/metalgo/l1/")) and (.logDir | startswith("/var/lib/metalgo/l1/"))' "$ccfg"
    done
    check "firewall: staking port open" has "$UFW_LOG" "allow 9651/tcp"
    check "firewall: SSH allowed before enabling" bash -c "grep -n 'allow 22/tcp' $UFW_LOG | head -1 | cut -d: -f1 | xargs -I{} test {} -lt \$(grep -n 'enable' $UFW_LOG | cut -d: -f1)"
    check "firewall: API port not opened" lacks "$UFW_LOG" "9650"
    check "automatic security updates" has /etc/apt/apt.conf.d/20auto-upgrades 'Unattended-Upgrade "1"'
    check "service enabled and started" has "$SYSTEMCTL_LOG" "systemctl start metalgo.service"
    check "no staking key made or read by setup.sh" test ! -e /var/lib/metalgo/staking

    step "re-run changes nothing"
    before=$(snapshot)
    : >"$SYSTEMCTL_LOG"
    setup --chains all --rpc >/tmp/run2.log
    check "same files, owners, modes and times" same_as "$before"
    check "no restart" test "$(restarts metalgo.service)" = 0
    check "reports a node metalgo-setup installed" has /tmp/run2.log "A node metalgo-setup installed"

    step "--status"
    setup --status >/tmp/status.log
    check "status lists all three L1s as on the node" bash -c "grep -c 'plugin yes' /tmp/status.log | grep -qx 3"
    check "no password in any output" no_secrets_printed
    ;;

  fresh-full)
    step "fresh install, full node, no L1s"
    setup --mode full --chains none >/tmp/run.log
    check "config: full primary network" jq -e '."partial-sync-primary-network" == false' /etc/metalgo/config.json
    check "config: no track-subnets" jq -e 'has("track-subnets") | not' /etc/metalgo/config.json
    check "unit says full" has /etc/systemd/system/metalgo.service "full primary network"
    check "no plugins" test -z "$(ls -A /opt/metalgo/plugins)"
    check "no build user without L1s" bash -c "! id metalgo-build 2>/dev/null"
    check "prints where the staking key and certificate are" has /tmp/run.log "/var/lib/metalgo/staking/staker.key"
    check "tells to back them up offline" has /tmp/run.log "Back these three files up offline"

    step "add BTCVM to it later"
    setup --chains btcvm >/tmp/run2.log
    check "still full" jq -e '."partial-sync-primary-network" == false' /etc/metalgo/config.json
    check "now tracks BTCVM" jq -e --arg t "$BTC_SUB" '."track-subnets" == $t' /etc/metalgo/config.json
    check "restarted once" test "$(restarts metalgo.service)" = 1
    check "BTCVM chain config without RPC" jq -e 'has("rpcPass") | not' "/var/lib/metalgo/configs/chains/$btcvm_CHAIN_ID/config.json"
    ;;

  flags-unit)
    make_flags_node
    unit=/etc/systemd/system/metal-mainnet.service
    step "dry run on an existing node (like the LTCVM server) changes nothing"
    before=$(snapshot)
    setup --chains btcvm,dogevm --dry-run >/tmp/dry.log
    check "found the unit" has /tmp/dry.log "Existing metalgo: metal-mainnet.service"
    check "read the data dir from the flags" has /tmp/dry.log "data dir: *\/opt\/ltcvm\/node"
    check "read the plugin dir" has /tmp/dry.log "plugin dir: *\/opt\/ltcvm\/plugins"
    check "read the API port" has /tmp/dry.log "http://127.0.0.1:9660"
    check "keeps LTCVM in the new track-subnets" has /tmp/dry.log "$LTC_SUB,$BTC_SUB,$DOGE_SUB"
    check "would restart once" test "$(grep -c '+ systemctl restart' /tmp/dry.log)" = 1
    check "nothing changed" same_as "$before"

    step "add BTCVM and DogecoinVM"
    ltc_before=$(sha256sum "/opt/ltcvm/plugins/$ltcvm_VM_ID" "/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json")
    setup --chains btcvm,dogevm >/tmp/run.log
    check "track-subnets: LTCVM kept, BTCVM and DogecoinVM added" test "$(tracked_in_unit "$unit")" = "$LTC_SUB,$BTC_SUB,$DOGE_SUB"
    check "only the track-subnets flag changed in the unit" \
      bash -c "diff <(sed 's/--track-subnets=[^ ]*//' $unit) <(sed 's/--track-subnets=[^ ]*//' /var/backups/metalgo-setup/*/etc/systemd/system/metal-mainnet.service)"
    check "the unit was backed up first" test -f /var/backups/metalgo-setup/*/etc/systemd/system/metal-mainnet.service
    check "LTCVM's plugin and config untouched" test "$ltc_before" = "$(sha256sum "/opt/ltcvm/plugins/$ltcvm_VM_ID" "/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json")"
    check "BTCVM plugin" owner_mode "/opt/ltcvm/plugins/$btcvm_VM_ID" "root 755"
    check "DogecoinVM plugin" owner_mode "/opt/ltcvm/plugins/$dogevm_VM_ID" "root 755"
    check "BTCVM chain config, the node user's" owner_mode "/opt/ltcvm/chain-configs/$btcvm_CHAIN_ID/config.json" "ltcvm 600"
    check "BTCVM data under the node's data dir" \
      jq -e '.dataDir == "/opt/ltcvm/node/l1/btcvm/data"' "/opt/ltcvm/chain-configs/$btcvm_CHAIN_ID/config.json"
    check "no stop drop-in (the unit has KillMode=mixed)" test ! -e /etc/systemd/system/metal-mainnet.service.d
    check "daemon-reload, then one restart" bash -c "grep -q 'daemon-reload' $SYSTEMCTL_LOG && test \$(grep -c 'restart metal-mainnet' $SYSTEMCTL_LOG) = 1"
    check "no metalgo user, config or firewall" bash -c "! id metalgo 2>/dev/null && test ! -e /etc/metalgo && test ! -e $UFW_LOG"

    step "re-run changes nothing"
    before=$(snapshot)
    : >"$SYSTEMCTL_LOG"
    setup --chains btcvm,dogevm >/tmp/run2.log
    check "same files" same_as "$before"
    check "no restart" test "$(restarts metal-mainnet.service)" = 0

    step "--remove dogevm keeps its data"
    touch /opt/ltcvm/node/l1/dogevm/data/blocks
    # In test mode there's no node API, so no NodeID: whether it validates
    # can't be told, and that refuses without --force.
    check "refuses when it can't tell whether the node validates" fails_with "can't tell whether it validates" --remove dogevm
    setup --remove dogevm --force >/tmp/rm.log
    check "DogecoinVM untracked, the others kept" test "$(tracked_in_unit "$unit")" = "$LTC_SUB,$BTC_SUB"
    check "DogecoinVM plugin gone" test ! -e "/opt/ltcvm/plugins/$dogevm_VM_ID"
    check "... and backed up" bash -c "ls /var/backups/metalgo-setup/*/opt/ltcvm/plugins/$dogevm_VM_ID >/dev/null"
    check "DogecoinVM data kept" test -f /opt/ltcvm/node/l1/dogevm/data/blocks
    check "DogecoinVM config kept" test -f "/opt/ltcvm/chain-configs/$dogevm_CHAIN_ID/config.json"

    step "--remove btcvm --purge deletes its data"
    setup --remove btcvm --purge --force >/tmp/purge.log
    check "only LTCVM tracked" test "$(tracked_in_unit "$unit")" = "$LTC_SUB"
    check "BTCVM data deleted" test ! -e /opt/ltcvm/node/l1/btcvm
    check "BTCVM config deleted" test ! -e "/opt/ltcvm/chain-configs/$btcvm_CHAIN_ID"
    check "LTCVM untouched" test "$ltc_before" = "$(sha256sum "/opt/ltcvm/plugins/$ltcvm_VM_ID" "/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json")"
    check "no password in any output" no_secrets_printed
    ;;

  config-file-unit)
    step "a node configured by a JSON file, default plugin dir, no KillMode"
    useradd --system --create-home --home-dir /home/node --shell /usr/sbin/nologin node
    install -m 0755 /usr/local/lib/fake-metalgo /usr/local/bin/metalgo
    install -d /etc/node
    cat >/etc/node/metalgo.json <<EOF
{
  "network-id": "1",
  "Data-Dir": "/srv/metal",
  "track-subnets": "$OTHER_SUB",
  "http-port": 9650,
  "index-enabled": true
}
EOF
    install -d -o node -g node /srv/metal
    cat >/etc/systemd/system/avalanche.service <<'EOF'
[Service]
User=node
ExecStart=/usr/local/bin/metalgo \
    --config-file=/etc/node/metalgo.json
[Install]
WantedBy=multi-user.target
EOF
    systemctl start avalanche
    setup --chains btcvm --rpc >/tmp/run.log
    cfg=/etc/node/metalgo.json
    check "config: the other L1 kept, BTCVM added" jq -e --arg t "$OTHER_SUB,$BTC_SUB" '."track-subnets" == $t' "$cfg"
    check "config: every other key kept" jq -e '."network-id" == "1" and ."Data-Dir" == "/srv/metal" and ."index-enabled" == true' "$cfg"
    check "config backed up" test -f /var/backups/metalgo-setup/*/etc/node/metalgo.json
    check "plugin in the default dir under the data dir" test -f "/srv/metal/plugins/$btcvm_VM_ID"
    check "chain config in the default dir" owner_mode "/srv/metal/configs/chains/$btcvm_CHAIN_ID/config.json" "node 600"
    check "unit itself unchanged" lacks /etc/systemd/system/avalanche.service track-subnets
    dropin=/etc/systemd/system/avalanche.service.d/10-metalgo-setup-stop.conf
    check "stop drop-in: KillMode=mixed" has "$dropin" '^KillMode=mixed$'
    check "stop drop-in: TimeoutStopSec=120" has "$dropin" '^TimeoutStopSec=120$'
    check "restarted" test "$(restarts avalanche.service)" = 1

    step "re-run changes nothing"
    before=$(snapshot)
    setup --chains btcvm --rpc >/dev/null
    check "same files" same_as "$before"
    check "no password in any output" no_secrets_printed
    ;;

  defaults-unit)
    step "a node with no flags at all: everything from metalgo's defaults"
    useradd --system --create-home --home-dir /home/metal --shell /usr/sbin/nologin metal
    install -m 0755 /usr/local/lib/fake-metalgo /usr/local/bin/metalgo
    printf '[Service]\nUser=metal\nExecStart=/usr/local/bin/metalgo\nKillMode=mixed\n' >/lib/systemd/system/metal.service
    setup --chains ltcvm --dry-run >/tmp/dry.log
    check "data dir: \$HOME/.metalgo" has /tmp/dry.log "data dir: */home/metal/.metalgo$"
    check "plugin dir: under it" has /tmp/dry.log "plugin dir: */home/metal/.metalgo/plugins$"
    check "chain config dir: configs/chains" has /tmp/dry.log "chain config dir: */home/metal/.metalgo/configs/chains$"
    setup --chains ltcvm >/tmp/run.log
    check "a stopped node stays stopped" lacks "$SYSTEMCTL_LOG" "systemctl start metal.service"
    check "... and says how to start it" has /tmp/run.log "leaving it stopped"
    setup --start >/tmp/run-start.log
    dropin=/etc/systemd/system/metal.service.d/20-metalgo-setup-exec.conf
    check "a packaged unit: ExecStart overridden in a drop-in" has "$dropin" "^ExecStart=/usr/local/bin/metalgo --track-subnets=$LTC_SUB$"
    check "the packaged unit untouched" lacks /lib/systemd/system/metal.service track-subnets
    check "plugin dir made" test -f "/home/metal/.metalgo/plugins/$ltcvm_VM_ID"
    check "chain config, the node user's" owner_mode "/home/metal/.metalgo/configs/chains/$ltcvm_CHAIN_ID/config.json" "metal 600"
    check "started with --start" has "$SYSTEMCTL_LOG" "systemctl start metal.service"
    setup --chains btcvm >/dev/null
    check "second L1 added to the drop-in" has "$dropin" "--track-subnets=$LTC_SUB,$BTC_SUB$"
    ;;

  refusals)
    make_flags_node
    before=$(snapshot)
    step "rpcchainvm mismatch"
    echo 42 >/etc/fake-metalgo-rpcchainvm
    check "refuses rpcchainvm=42" fails_with "speaks plugin protocol rpcchainvm=42, but the L1 plugins need rpcchainvm=43" --chains btcvm
    rm /etc/fake-metalgo-rpcchainvm
    check "nothing changed" same_as "$before"

    step "not mainnet"
    sed -i 's/--network-id=mainnet/--network-id=tahoe/' /etc/systemd/system/metal-mainnet.service
    check "refuses tahoe" fails_with "Metal mainnet only" --chains btcvm
    sed -i 's/--network-id=tahoe/--network-id=mainnet/' /etc/systemd/system/metal-mainnet.service

    step "two metalgo services"
    sed 's/Description=.*/Description=second/' /etc/systemd/system/metal-mainnet.service >/etc/systemd/system/metal-2.service
    check "asks which" fails_with "pass --unit NAME" --chains btcvm --dry-run
    check "--unit picks one" bash -c "/src/setup.sh --unit metal-mainnet --chains btcvm --dry-run >/dev/null"
    rm /etc/systemd/system/metal-2.service

    step "track-subnets from the environment"
    sed -i "s/ --track-subnets=[^ ]*//; s|^Environment=HOME=/home/ltcvm|Environment=HOME=/home/ltcvm AVAGO_TRACK_SUBNETS=$LTC_SUB|" /etc/systemd/system/metal-mainnet.service
    check "reads it" bash -c "/src/setup.sh --status 2>&1 | grep -q 'track-subnets: *$LTC_SUB (from env)'"
    check "won't edit it" fails_with "AVAGO_TRACK_SUBNETS=$LTC_SUB,$BTC_SUB yourself" --chains btcvm

    step "bad options"
    check "unknown chain" fails_with "unknown chain 'ethvm'" --chains ethvm --dry-run
    check "unknown mode" fails_with "--mode is full or l1-only" --mode half --dry-run
    check "--purge without --remove" fails_with "--purge goes with --remove" --purge --dry-run
    ;;

  config-file-options)
    step "options from /etc/metalgo-setup.conf, overridden by flags"
    make_flags_node
    printf '# test\nchains = btcvm,dogevm\nrpc = yes\nrestart = no\n' >/etc/metalgo-setup.conf
    setup >/tmp/run.log
    check "took chains from the file" test -f "/opt/ltcvm/plugins/$dogevm_VM_ID"
    check "took rpc from the file" jq -e '.rpcPass' "/opt/ltcvm/chain-configs/$btcvm_CHAIN_ID/config.json" >/dev/null
    check "took restart=no from the file" test "$(restarts metal-mainnet.service)" = 0
    check "said how to restart" has /tmp/run.log "systemctl restart metal-mainnet"
    printf 'bogus = 1\n' >/etc/metalgo-setup.conf
    check "rejects unknown settings" fails_with "unknown setting 'bogus'" --dry-run
    ;;

  validator-settings)
    step "fee address and validator admins in the chain config"
    make_flags_node
    # A copy of the repo with an admin pinned for BTCVM (the pins ship empty).
    cp -r /src /tmp/repo
    ADMIN=P-metal1qyqszqgpqyqszqgpqyqszqgpqyqszqgpzj5rty
    ADMIN2=P-metal1qgpqyqszqgpqyqszqgpqyqszqgpqyqsznkjxqj
    sed -i "s|^btcvm_VALIDATOR_ADMINS=\"\"|btcvm_VALIDATOR_ADMINS=\"$ADMIN $ADMIN2\"|" /tmp/repo/lib/pins.sh
    sed -i 's|^btcvm_VALIDATOR_ADMIN_THRESHOLD=""|btcvm_VALIDATOR_ADMIN_THRESHOLD="3"|' /tmp/repo/lib/pins.sh
    SETUP=/tmp/repo/setup.sh check "refuses a threshold above the admins" fails_with "must be between 1 and its 2 admins" --chains btcvm --dry-run
    sed -i 's|^btcvm_VALIDATOR_ADMIN_THRESHOLD="3"|btcvm_VALIDATOR_ADMIN_THRESHOLD="2"|' /tmp/repo/lib/pins.sh
    FEES=bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq # a public example address
    check "refuses a non-BTCVM fee address" fails_with "isn't a BTCVM address" --chains btcvm --mining-address btcvm=DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L --dry-run
    check "refuses a chain that isn't here" fails_with "isn't on this node" --mining-address dogevm=DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L
    /tmp/repo/setup.sh --chains btcvm --mining-address "btcvm=$FEES" 2>&1 | tee -a "$OUT" >/tmp/run.log
    cfg=/opt/ltcvm/chain-configs/$btcvm_CHAIN_ID/config.json
    check "miningAddrs set" jq -e --arg a "$FEES" '.miningAddrs == [$a]' "$cfg"
    check "validatorAdmins from the pins" jq -e --arg a "$ADMIN" --arg b "$ADMIN2" '.validatorAdmins == [$a, $b]' "$cfg"
    check "validatorAdminThreshold from the pins" jq -e '.validatorAdminThreshold == 2' "$cfg"
    check "config still 600, the node user's" owner_mode "$cfg" "ltcvm 600"
    check "LTCVM's config untouched (no LTCVM fee address given, no LTCVM admins pinned)" \
      jq -e 'has("miningAddrs") | not' "/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json"

    step "changing only the fee address later"
    : >"$SYSTEMCTL_LOG"
    FEES2=bc1q9vza2e8x573nczrlzms0wvx3gsqjx7vavgkx0l
    /tmp/repo/setup.sh --mining-address "btcvm=$FEES2" >/tmp/run2.log 2>&1
    check "miningAddrs replaced" jq -e --arg a "$FEES2" '.miningAddrs == [$a]' "$cfg"
    check "other keys kept" jq -e '.dataDir and .validatorAdmins' "$cfg"
    check "the old config backed up" bash -c "ls /var/backups/metalgo-setup/*$cfg >/dev/null"

    check "restarted to load it" test "$(restarts metal-mainnet.service)" = 1
    check "no password in any output" no_secrets_printed

    step "new admins, no pinned threshold: the old threshold goes (the plugin's default applies)"
    ADMIN3=P-metal1qvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrjxn82n
    sed -i "s|^btcvm_VALIDATOR_ADMINS=.*|btcvm_VALIDATOR_ADMINS=\"$ADMIN $ADMIN2 $ADMIN3\"|" /tmp/repo/lib/pins.sh
    sed -i 's|^btcvm_VALIDATOR_ADMIN_THRESHOLD=.*|btcvm_VALIDATOR_ADMIN_THRESHOLD=""|' /tmp/repo/lib/pins.sh
    /tmp/repo/setup.sh --mining-address "btcvm=$FEES2" >/tmp/run3.log 2>&1
    check "three admins" jq -e '.validatorAdmins | length == 3' "$cfg"
    check "no stale threshold" jq -e 'has("validatorAdminThreshold") | not' "$cfg"
    ;;

  workdir-guard)
    step "a node whose working directory is its data dir"
    make_flags_node
    unit=/etc/systemd/system/metal-mainnet.service
    sed -i 's|^WorkingDirectory=.*|WorkingDirectory=/opt/ltcvm/node|' "$unit"
    mkdir -p /opt/ltcvm/node/db && echo "metalgo's database" >/opt/ltcvm/node/db/000001.sst
    setup --chains btcvm >/tmp/run.log
    dropin=/etc/systemd/system/metal-mainnet.service.d/30-metalgo-setup-workdir.conf
    check "warned about the working directory" has /tmp/run.log "isn't safe for the L1 plugins"
    check "moved it to an empty directory of its own" has "$dropin" '^WorkingDirectory=/opt/ltcvm/node/metalgo-setup-workdir$'
    check "that directory exists, the node user's" owner_mode /opt/ltcvm/node/metalgo-setup-workdir "ltcvm 750"
    check "metalgo's database untouched" test -f /opt/ltcvm/node/db/000001.sst
    setup --chains btcvm >/tmp/run2.log
    check "a re-run finds it safe" has /tmp/run2.log "working directory /opt/ltcvm/node/metalgo-setup-workdir is safe"

    step "relative paths: refuses to move the working directory"
    rm -rf /etc/systemd/system/metal-mainnet.service.d "/opt/ltcvm/plugins/$btcvm_VM_ID"
    sed -i 's|--log-dir=/opt/ltcvm/logs|--log-dir=logs|' "$unit"
    check "refuses, and says what to do" fails_with "settings use relative paths" --chains btcvm

    step "a relative dataDir in a chain config: refuses too"
    sed -i 's|--log-dir=logs|--log-dir=/opt/ltcvm/logs|' "$unit"
    cc=/opt/ltcvm/chain-configs/$ltcvm_CHAIN_ID/config.json
    jq '.dataDir = "chaindata"' "$cc" >/tmp/cc.json && cp /tmp/cc.json "$cc"
    check "refuses, naming the chain config" fails_with "chain configs with relative paths" --chains btcvm
    ;;

  own-metalgo-unit)
    step "an operator's own metalgo.service, given metalgo-setup's drop-ins, stays theirs"
    make_flags_node
    systemctl stop metal-mainnet
    # Named as metalgo-setup names its own, without KillMode (so it gets the
    # stop drop-in, which carries metalgo-setup's mark).
    sed '/^KillMode=/d; /^TimeoutStopSec=/d' /etc/systemd/system/metal-mainnet.service >/etc/systemd/system/metalgo.service
    rm /etc/systemd/system/metal-mainnet.service
    systemctl start metalgo
    setup --chains btcvm --yes >/tmp/run.log
    check "the stop drop-in was added" bash -c "ls /etc/systemd/system/metalgo.service.d/*metalgo-setup* >/dev/null"
    unit_before=$(sha256sum /etc/systemd/system/metalgo.service) # with its --track-subnets
    setup --update --yes >/tmp/run2.log
    check "not taken for metalgo-setup's own install" lacks /tmp/run2.log "A node metalgo-setup installed"
    check "no fresh config written" test ! -e /etc/metalgo/config.json
    check "the operator's unit untouched" test "$(sha256sum /etc/systemd/system/metalgo.service)" = "$unit_before"
    check "still its own data dir" grep -q -- "--data-dir=/opt/ltcvm/node" /etc/systemd/system/metalgo.service
    ;;

  *) echo "unknown scenario $SCENARIO" >&2; exit 2 ;;
esac
echo
echo "PASSED $SCENARIO"
