#!/usr/bin/env bash
# metalgo-setup: sets up a Metal Blockchain node on Ubuntu 24.04 and adds
# Metal's UTXO L1s (BTCVM, LTCVM, DogecoinVM) to it, or to a node that is
# already running.
#
#   sudo ./setup.sh                      a short menu
#   sudo ./setup.sh [options]            see --help
#
# On a fresh server it installs the pinned metalgo as its own user, with a
# hardened systemd unit, a firewall and automatic security updates. On a
# server that already runs metalgo it changes only what adding (or removing)
# the L1s needs: the plugins, their chain configs and track-subnets.
#
# It never makes, reads, prints or copies a private key. Every file it
# changes is backed up first. Safe to re-run; --dry-run changes nothing.
#
# Developed by Paul Grey @ metallicus.com.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/pins.sh
source "$REPO_DIR/lib/pins.sh"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$REPO_DIR/lib/detect.sh"
# shellcheck source=lib/chains.sh
source "$REPO_DIR/lib/chains.sh"
# shellcheck source=lib/fresh.sh
source "$REPO_DIR/lib/fresh.sh"

usage() {
  cat <<EOF
usage: sudo ./setup.sh [options]          (no options: a short menu)

  --mode full|l1-only     fresh install only. l1-only (default): sync just the
                          P-Chain, the light way to follow the L1s. full: the
                          whole primary network (can validate Metal and earn
                          staking rewards; needs far more disk and RAM)
  --chains LIST           L1s to add: any of btcvm,ltcvm,dogevm, or all, or none
  --rpc                   give each new L1 a local JSON-RPC (random user and
                          password in its chain config, mode 0600) with
                          txIndex/addrIndex
  --mining-address CHAIN=ADDRESS
                          where this node's block fees go once it validates
                          CHAIN's L1 (its own BTCVM, LTCVM or DogecoinVM
                          address; repeatable). Needed to build blocks.
  --remove LIST           L1s to remove (their data is kept unless --purge)
  --purge                 with --remove: delete the L1s' data and configs too
  --update                rebuild the L1s already on this node at the current
                          pins (and, on a node metalgo-setup installed, metalgo)
  --allow-downgrade       install an L1 plugin that isn't newer than the one
                          metalgo-setup installed here (refused otherwise)
  --unit NAME             the existing metalgo's systemd service (default: found)
  --no-restart            change files but don't restart metalgo (restart it
                          yourself when it suits: systemctl restart UNIT)
  --start                 start an existing metalgo service that is stopped
                          (a stopped one is otherwise left stopped)
  --wait SECONDS          how long to wait for the L1s to bootstrap (default
                          900; 0: don't wait)
  --harden-ssh            fresh install: key logins only (only if a key exists)
  --public-ip IP          fresh install: this server's public IPv4 (default:
                          detected)
  --build-from-source     fresh install: build metalgo from its pinned commit
                          instead of the official release tarball
  --config FILE           read options from FILE (default: $DEFAULT_CONF, if it
                          exists); command-line options win
  --status                show the node and its L1s; change nothing
  --dry-run               print every action without doing any of them
  -y, --yes               don't ask before restarting metalgo
  -h, --help              this help

Chains: btcvm (BTCVM), ltcvm (LTCVM), dogevm (DogecoinVM). See README.md.
EOF
}

DEFAULT_CONF=/etc/metalgo-setup.conf

# --- Options: defaults < config file < command line ------------------------------------
MODE='' CHAINS_OPT='' REMOVE_OPT='' RPC=0 UNIT_ARG='' RESTART=1 WAIT_SECS=900 WAIT_SET=0
HARDEN_SSH=0 PUBLIC_IP_ARG='' FROM_SOURCE=0 PURGE=0 FORCE=0 YES=0 STATUS=0 UPDATE=0 ALLOW_DOWNGRADE=0 START=0 MODE_FROM_FILE=0
CONF_FILE='' MENU=0

yes_value() {
  case ${2,,} in
    1 | y | yes | true | on) printf 1 ;;
    0 | n | no | false | off | '') printf 0 ;;
    *) die "$1: '$2' is not yes or no" ;;
  esac
}

# load_conf FILE: key=value lines, the option names without "--". Not
# sourced: only these keys are read.
load_conf() {
  local file=$1 line k v n=0
  [[ -r $file ]] || die "can't read $file"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^[[:space:]]*([a-z-]+)[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]] ||
      die "$file:$n: expected key=value"
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    case $k in
      mode) MODE=$v MODE_FROM_FILE=1 ;;
      chains) CHAINS_OPT=$v ;;
      rpc) RPC=$(yes_value "$file:$n" "$v") ;;
      unit) UNIT_ARG=$v ;;
      restart) RESTART=$(yes_value "$file:$n" "$v") ;;
      wait) WAIT_SECS=$v WAIT_SET=1 ;;
      harden-ssh) HARDEN_SSH=$(yes_value "$file:$n" "$v") ;;
      public-ip) PUBLIC_IP_ARG=$v ;;
      build-from-source) FROM_SOURCE=$(yes_value "$file:$n" "$v") ;;
      mining-address) set_mining_address "$v" ;;
      *) die "$file:$n: unknown setting '$k'" ;;
    esac
  done <"$file"
}

# set_mining_address CHAIN=ADDRESS: checks the address is one of CHAIN's.
set_mining_address() {
  local c=${1%%=*} a=${1#*=} re
  [[ $1 == *=* && -n $a ]] || die "--mining-address takes CHAIN=ADDRESS (e.g. btcvm=bc1q...)"
  c=$(parse_chain_list "$c")
  [[ -n $c && $c != *" "* ]] || die "--mining-address: name one chain, as CHAIN=ADDRESS"
  re=$(chain_var "$c" ADDRESS_RE)
  [[ $a =~ $re ]] || die "--mining-address: '$a' isn't a $(chain_var "$c" TITLE) address; a validator with a bad one builds no blocks"
  printf -v "MINING_$c" '%s' "$a"
  MINING_CHAINS+=" $c"
}
MINING_CHAINS=''

ARGS=("$@")
# The config file first, so the command line can override it.
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  [[ ${ARGS[i]} == --config ]] && CONF_FILE=${ARGS[i + 1]:-}
  [[ ${ARGS[i]} == --config=* ]] && CONF_FILE=${ARGS[i]#--config=}
done
if [[ -n $CONF_FILE ]]; then
  load_conf "$CONF_FILE"
elif [[ -r $DEFAULT_CONF ]]; then
  CONF_FILE=$DEFAULT_CONF
  load_conf "$CONF_FILE"
fi
# No options and no config file: the menu (on a terminal).
if ((${#ARGS[@]} == 0)) && [[ -z $CONF_FILE ]]; then
  if [[ -t 0 && -t 1 ]]; then MENU=1; else
    usage >&2
    exit 2
  fi
fi

need() { [[ -n ${2:-} && ${2:-} != --* ]] || die "$1 needs a value (see --help)"; }
while (($#)); do
  opt=$1 val=''
  if [[ $opt == --*=* ]]; then
    val=${opt#*=} opt=${opt%%=*}
    set -- "$opt" "$val" "${@:2}"
  fi
  case $opt in
    --mode) need "$1" "${2:-}"; MODE=$2 MODE_FROM_FILE=0; shift ;;
    --chains) need "$1" "${2:-}"; CHAINS_OPT=$2; shift ;;
    --remove) need "$1" "${2:-}"; REMOVE_OPT=$2; shift ;;
    --unit) need "$1" "${2:-}"; UNIT_ARG=${2%.service}; shift ;;
    --wait) need "$1" "${2:-}"; WAIT_SECS=$2 WAIT_SET=1; shift ;;
    --public-ip) need "$1" "${2:-}"; PUBLIC_IP_ARG=$2; shift ;;
    --mining-address) need "$1" "${2:-}"; set_mining_address "$2"; shift ;;
    --config) shift ;;
    --rpc) RPC=1 ;;
    --no-restart) RESTART=0 ;;
    --start) START=1 ;;
    --purge) PURGE=1 ;;
    --force) FORCE=1 ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
    --update) UPDATE=1 ;;
    --harden-ssh) HARDEN_SSH=1 ;;
    --build-from-source) FROM_SOURCE=1 ;;
    --status) STATUS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -y | --yes) YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

case $MODE in '' | full | l1-only) ;; *) die "--mode is full or l1-only, not '$MODE'" ;; esac
[[ $WAIT_SECS =~ ^[0-9]+$ ]] || die "--wait takes seconds, not '$WAIT_SECS'"
[[ -z $PUBLIC_IP_ARG || $PUBLIC_IP_ARG =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--public-ip $PUBLIC_IP_ARG is not an IPv4 address"
chains_list=$(parse_chain_list "$CHAINS_OPT") || exit 1
remove_list=$(parse_chain_list "$REMOVE_OPT") || exit 1
read -r -a CHAINS <<<"$chains_list"
read -r -a REMOVE <<<"$remove_list"
for c in ${REMOVE[@]+"${REMOVE[@]}"}; do
  [[ " ${CHAINS[*]:-} " == *" $c "* ]] && die "$c is both in --chains and --remove"
done
((PURGE)) && ((${#REMOVE[@]} == 0)) && die "--purge goes with --remove"

# --- The situation -------------------------------------------------------------------
# detect_existing UNIT: reads the unit and everything metalgo will use.
detect_existing() {
  read_unit "$1"
  resolve_node
}

SITUATION='' UNIT_MANAGED_BEFORE=0
detect_situation() {
  local units=() u
  if [[ -n $UNIT_ARG ]]; then
    detect_existing "$UNIT_ARG"
  else
    while IFS= read -r u; do [[ -n $u ]] && units+=("$u"); done < <(find_metalgo_units)
    case ${#units[@]} in
      0)
        if pgrep -x metalgo >/dev/null 2>&1; then
          die "metalgo is running, but not as a systemd service metalgo-setup can find. Pass --unit NAME, or run it as a systemd service first."
        fi
        SITUATION=fresh
        fresh_layout
        return 0
        ;;
      1) detect_existing "${units[0]}" ;;
      *) die "found more than one metalgo service (${units[*]}); pass --unit NAME" ;;
    esac
  fi
  # Ours only if metalgo-setup wrote the unit itself, in its own place, running
  # its own layout: never a node that merely has one of its drop-ins.
  if ((UNIT_MANAGED)) && [[ $UNIT_NAME == "$FRESH_UNIT" && ${UNIT_FILES[0]:-} == "/etc/systemd/system/$FRESH_UNIT.service" &&
    $UNIT_EXEC == *"--config-file=$FRESH_CONFIG"* ]]; then
    SITUATION=ours UNIT_MANAGED_BEFORE=1
  else
    SITUATION=existing
  fi
}

# The chains on this node: a plugin for its VM, or its subnet tracked.
installed_chains() {
  local c out=()
  for c in $ALL_CHAINS; do
    if [[ -f $PLUGIN_DIR/$(chain_var "$c" VM_ID) ]] || is_tracked "$(chain_var "$c" SUBNET_ID)"; then out+=("$c"); fi
  done
  printf '%s' "${out[*]:-}"
}

show_node() {
  log "Existing metalgo: $UNIT_NAME.service"
  info "binary:           $NODE_BIN"
  info "runs as:          $UNIT_USER:$UNIT_GROUP"
  info "config file:      ${CFG_FILE:-${CFG_SRC:-none}}"
  info "data dir:         $DATA_DIR"
  info "plugin dir:       $PLUGIN_DIR"
  info "chain config dir: $CHAIN_CONFIG_DIR"
  info "network:          $NETWORK"
  info "track-subnets:    $(IFS=,; printf '%s' "${TRACKED[*]:-none}") (from ${TRACK_SRC/default/nowhere: not set})"
  info "primary network:  $( ((PARTIAL_SYNC)) && echo 'P-Chain only (partial sync)' || echo full)"
  info "API:              $NODE_API"
}

# --- The menu -----------------------------------------------------------------------
menu() {
  echo
  log "metalgo-setup: a Metal Blockchain node and the UTXO L1s"
  echo
  local installed='' c title
  if [[ $SITUATION == fresh ]]; then
    info "No metalgo here yet: this sets up a new node (Ubuntu 24.04)."
    echo
    info "1) l1-only  sync just the P-Chain: light (2 vCPU, 4 GB RAM, 40 GB SSD"
    info "            with all three L1s), the way to follow the L1s"
    info "2) full     the whole primary network: can validate Metal and earn"
    info "            staking rewards (8 vCPU, 16 GB RAM, 250 GB SSD or more)"
    local a
    read -r -p "    Node type [1]: " a </dev/tty || a=''
    case ${a:-1} in 1 | l1-only) MODE=l1-only ;; 2 | full) MODE=full ;; *) die "no such choice: $a" ;; esac
  else
    show_node
    installed=$(installed_chains)
  fi
  echo
  info "The L1s (followers of each L1; ~180 MB RAM each):"
  CHAINS=()
  for c in $ALL_CHAINS; do
    title=$(chain_var "$c" TITLE)
    if [[ " $installed " == *" $c "* ]]; then
      yes_no "    $title is on this node; rebuild it at the current pin?" n && CHAINS+=("$c")
    else
      yes_no "    Add $title?" y && CHAINS+=("$c")
    fi
  done
  if ((${#CHAINS[@]})); then
    yes_no "    A local JSON-RPC for each new L1 (random password, localhost only)?" n && RPC=1
  fi
  if [[ $SITUATION == fresh ]]; then
    yes_no "    SSH: key logins only (skipped if no key is set up)?" n && HARDEN_SSH=1
  fi
  echo
  yes_no "    Show everything it would do first (a dry run)?" y && DRY_RUN=1
}

# --- Checks ---------------------------------------------------------------------------
preflight() {
  if [[ $EUID -ne 0 ]]; then
    ((DRY_RUN || STATUS)) || die "run as root: sudo ./setup.sh ..."
    warn "not root: fine for a dry run, but some files can't be read, and the real run needs sudo"
  fi
  local mem_kb avail_mb total_mb dir free_gb adding=${#CHAINS[@]}
  mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
  avail_mb=$((${mem_kb:-0} / 1024))
  total_mb=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024))
  dir=$DATA_DIR
  while [[ ! -d $dir ]]; do dir=$(dirname "$dir"); done
  free_gb=$(df -P -BG "$dir" 2>/dev/null | awk 'NR == 2 {sub("G", "", $4); print $4}' || true)
  info "memory available: ${avail_mb} MB of ${total_mb} MB; disk free under $dir: ${free_gb:-?} GB"
  if ((mem_kb && avail_mb < WARN_MEM_AVAILABLE_MB)); then
    warn "only $avail_mb MB of memory available; each L1 plugin needs about $PLUGIN_RAM_MB MB"
  elif ((adding && mem_kb && avail_mb < adding * PLUGIN_RAM_MB + 256)); then
    warn "$avail_mb MB of memory available; $adding L1 plugin(s) need about $((adding * PLUGIN_RAM_MB)) MB"
  fi
  if [[ -n $free_gb ]] && ((free_gb < WARN_DISK_FREE_GB)); then
    warn "only $free_gb GB of disk free under $dir"
  fi
  if [[ $SITUATION == fresh || $SITUATION == ours ]]; then
    if [[ $MODE == full ]] && ((total_mb && total_mb < 15000)); then
      warn "a full primary-network node needs 16 GB RAM (metalgo's minimum: 8 vCPU, 16 GiB RAM, 250 GiB SSD); this server has $total_mb MB"
    elif ((total_mb && total_mb < 3500)); then
      warn "an l1-only node with the three L1s needs 4 GB RAM (2 vCPU, 4 GB RAM, 40 GB SSD); this server has $total_mb MB"
    fi
  fi
}

check_existing() {
  network_is_mainnet "$NETWORK" || die "$UNIT_NAME runs on network '$NETWORK'; metalgo-setup is for Metal mainnet only"
  [[ -x $NODE_BIN ]] || die "$UNIT_NAME.service runs $NODE_BIN, which isn't an executable file"
  local v
  v=$(metalgo_version "$NODE_BIN" "$UNIT_USER")
  [[ $v =~ rpcchainvm=([0-9]+) ]] || die "can't tell the plugin protocol of $NODE_BIN ('$NODE_BIN --version' says '$v')"
  if [[ ${BASH_REMATCH[1]} != "$METALGO_RPCCHAINVM" ]]; then
    die "$NODE_BIN speaks plugin protocol rpcchainvm=${BASH_REMATCH[1]}, but the L1 plugins need rpcchainvm=$METALGO_RPCCHAINVM (metalgo v1.13.4 or $METALGO_VERSION). Upgrade metalgo first, then re-run."
  fi
  ok "$v"
  if ((${#CHAINS[@]})) && [[ $(stat -c '%U' "$DATA_DIR" 2>/dev/null) != "$UNIT_USER" ]] && ! ((DRY_RUN)); then
    warn "$DATA_DIR is owned by $(stat -c '%U' "$DATA_DIR"), not $UNIT_USER; the L1s' data goes under it"
  fi
}

# What the node validates, and what a restart means for it.
NODE_ID='' IS_VALIDATOR=0 VALIDATES_L1=()
node_role() {
  ((TEST_ONLY)) && return 0
  if [[ $SITUATION == fresh ]] || ! systemctl is-active --quiet "$UNIT_NAME.service" 2>/dev/null; then
    return 0
  fi
  NODE_ID=$(node_id)
  if [[ -z $NODE_ID ]]; then
    warn "$UNIT_NAME is running but its API ($NODE_API) doesn't answer; can't tell whether it validates"
    return 0
  fi
  info "NodeID:           $NODE_ID"
  if [[ $(validates "$NODE_ID") == true ]]; then
    IS_VALIDATOR=1
    info "role:             ${BOLD}a validator of the Metal primary network${RESET}"
  fi
  local c
  for c in $ALL_CHAINS; do
    [[ $(validates "$NODE_ID" "$(chain_var "$c" SUBNET_ID)") == true ]] && VALIDATES_L1+=("$(chain_var "$c" TITLE)")
  done
  ((${#VALIDATES_L1[@]})) && info "validates L1s:    ${VALIDATES_L1[*]}"
  return 0
}

apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  if ((TEST_ONLY)); then
    info "TEST MODE: not installing ${missing[*]}"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -q
  run apt-get install -yq --no-install-recommends "${missing[@]}"
}

# --- Restarting ------------------------------------------------------------------------
restart_node() {
  local unit=$UNIT_NAME.service
  if ((UNIT_FILES_CHANGED)); then
    run systemctl daemon-reload
  fi
  if [[ $SITUATION != existing ]]; then
    run systemctl enable "$unit"
  fi
  if [[ $SITUATION != fresh ]] && ! ((START)) && ! ((DRY_RUN)) && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
    # Stopped on purpose, perhaps for maintenance, or moved to another server
    # with the same staking key (two copies must never run): left stopped.
    RESTARTED=0
    warn "$UNIT_NAME is stopped; leaving it stopped. Start it when ready: sudo systemctl start $UNIT_NAME (or re-run with --start)"
    return 0
  fi
  if [[ $SITUATION == fresh ]] || { ! ((DRY_RUN)) && ! systemctl is-active --quiet "$unit" 2>/dev/null; }; then
    log "Starting $UNIT_NAME"
    run systemctl start "$unit"
    return 0
  fi
  if ! ((NODE_CHANGED || METALGO_CHANGED)); then
    ok "nothing changed; $UNIT_NAME keeps running"
    RESTARTED=0
    return 0
  fi
  if ! ((RESTART)); then
    RESTARTED=0
    warn "not restarting $UNIT_NAME (--no-restart). The changes take effect when you run: sudo systemctl restart $UNIT_NAME"
    return 0
  fi
  if ((DRY_RUN)); then
    log "Restarting $UNIT_NAME (metalgo loads plugins and track-subnets only at start)"
    run systemctl restart "$unit"
    return 0
  fi
  if ! ((YES)) && [[ -t 0 && -t 1 ]]; then
    yes_no "Restart $UNIT_NAME now? It stops for a few seconds while metalgo restarts." y || {
      RESTARTED=0
      warn "not restarted. The changes take effect when you run: sudo systemctl restart $UNIT_NAME"
      return 0
    }
  fi
  log "Restarting $UNIT_NAME"
  run systemctl restart "$unit"
}

# --- Doing it ----------------------------------------------------------------------------
followers_note() {
  cat <<EOF

The L1s run here as ${BOLD}followers${RESET} for now: this node syncs them, checks every
block and serves them, but doesn't validate them until the L1's admins
approve it (and while no admins are pinned, the L1s take no new validators). It is ready to be registered as a validator of each L1 later,
when that opens (you'll need its NodeID: sudo ./setup.sh --status).

No peg keys, and no Bitcoin, Litecoin or Dogecoin node, are needed for this:
those are only for bridge signers (github.com/paulgnz/bridge-operator).
EOF
}

# desired_tracked: TRACKED, plus the chosen L1s' subnets, minus the removed.
desired_tracked() {
  local s c out=() drop=' '
  for c in ${REMOVE[@]+"${REMOVE[@]}"}; do drop+="$(chain_var "$c" SUBNET_ID) "; done
  for s in ${TRACKED[@]+"${TRACKED[@]}"}; do
    [[ $drop == *" $s "* ]] || out+=("$s")
  done
  for c in ${CHAINS[@]+"${CHAINS[@]}"}; do
    s=$(chain_var "$c" SUBNET_ID)
    [[ " ${out[*]:-} " == *" $s "* ]] || out+=("$s")
  done
  printf '%s\n' ${out[@]+"${out[@]}"}
}

status() {
  if [[ $SITUATION == fresh ]]; then
    log "No metalgo service on this machine"
    return 0
  fi
  show_node
  node_role
  local c title vmid stamp installed=()
  log "The L1s"
  for c in $ALL_CHAINS; do
    title=$(chain_var "$c" TITLE) vmid=$(chain_var "$c" VM_ID)
    stamp=$(cut -d' ' -f1 "$STATE_DIR/built/$c" 2>/dev/null || true)
    local plugin=no tracked=no cfg boot=''
    [[ -f $PLUGIN_DIR/$vmid ]] && plugin=yes
    is_tracked "$(chain_var "$c" SUBNET_ID)" && tracked=yes
    cfg=$(existing_chain_config "$c" || true)
    [[ $plugin == no && $tracked == no ]] && { info "$title: not on this node"; continue; }
    installed+=("$c")
    [[ -n $NODE_ID ]] && boot=$(is_bootstrapped "$(chain_var "$c" CHAIN_ID)")
    info "$title: plugin $plugin${stamp:+ (built at ${stamp:0:12}$([[ $stamp != "$(chain_var "$c" COMMIT)" ]] && echo ', not the current pin: run --update'))}, tracked $tracked, config ${cfg:-none}, bootstrapped ${boot:-?}"
  done
  if [[ -n $NODE_ID ]] && ((${#installed[@]})); then
    report_heights "${installed[@]}"
    validator_report "${installed[@]}"
  fi
}

# validator_report CHAIN...: for each L1, whether this node validates it,
# where its fees go, and how to apply.
validator_report() {
  local c title cfg mining reply weight bal vid tool apply=0
  log "Validating the L1s"
  for c in "$@"; do
    title=$(chain_var "$c" TITLE) tool=$(chain_var "$c" L1_TOOL)
    cfg=$(existing_chain_config "$c" || true)
    mining=''
    [[ -n $cfg ]] && mining=$(jq -r '.miningAddrs[0] // empty' "$cfg" 2>/dev/null || true)
    reply=$(node_call bc/P platform.getCurrentValidators "{\"subnetID\":\"$(chain_var "$c" SUBNET_ID)\",\"nodeIDs\":[\"$NODE_ID\"]}")
    weight=$(jq -r '.result.validators[0].weight // empty' <<<"$reply" 2>/dev/null || true)
    if [[ -n $weight ]]; then
      bal=$(jq -r '.result.validators[0].balance // empty' <<<"$reply" 2>/dev/null || true)
      vid=$(jq -r '.result.validators[0].validationID // empty' <<<"$reply" 2>/dev/null || true)
      info "$title: ${BOLD}validator${RESET}, weight $weight${bal:+, $(awk -v b="$bal" 'BEGIN { printf "%.3f", b / 1e9 }') METAL left for the P-Chain fee}${vid:+ (validation $vid)}"
      if [[ -n $mining ]]; then
        info "    block fees go to $mining"
      else
        warn "$title: this node validates but has no miningAddrs, so it builds no blocks and earns nothing: sudo ./setup.sh --mining-address $c=YOUR_ADDRESS"
      fi
    elif [[ -z $(chain_var "$c" VALIDATOR_ADMINS) ]]; then
      # No admins pinned: this L1's validators can't approve anyone yet
      # (they must first run the validator-manager plugin, with admins).
      info "$title: follower. This L1 doesn't take new validators yet."
    else
      info "$title: follower (not a validator)${mining:+; fees would go to $mining}"
      info "    to apply: $tool request -node-uri $NODE_API -owner P-metal1YOUR_ADDRESS > request.json"
      apply=1
    fi
  done
  if ((apply)); then
    cat <<EOF

    To validate an L1 and earn its block fees: send the L1's admins the
    request above (all public: your NodeID, BLS key and proof of possession,
    and the P-Chain address that owns the validator's METAL balance). Once
    enough of them approve, you get back registration.json; register it yourself, paying the validator's
    P-Chain fee balance (about 1.3 METAL a month) with your own P-Chain key:
        <chain>-l1 register -registration registration.json -key your-p-chain-key.json -balance 5
    and set where your block fees go (restarts once):
        sudo ./setup.sh --mining-address CHAIN=YOUR_ADDRESS
    The tools are in each L1's repo (cmd/btcvm-l1, cmd/ltcvm-l1, cmd/dogevm-l1).
EOF
  fi
}

main() {
  if ((DRY_RUN)); then
    log "DRY RUN: nothing below is done; each action is printed"
  fi
  if ((TEST_ONLY)); then
    [[ -f /.dockerenv ]] || die "METALGO_SETUP_TEST_ONLY is for the container tests only"
    warn "TEST MODE: nothing is downloaded or built, and the network isn't used"
  fi
  # detect.sh needs jq and perl (both tiny).
  if ! command -v jq >/dev/null || ! command -v perl >/dev/null || ! command -v curl >/dev/null; then
    if ((DRY_RUN || STATUS)); then
      warn "jq, perl and curl are needed to read this node's settings; the real run installs them (apt-get install jq perl curl)"
    else
      apt_install jq perl curl ca-certificates
    fi
  fi
  detect_situation
  if ((MENU)); then menu; fi
  if ((STATUS)); then
    status
    return 0
  fi
  if ((UPDATE)); then
    [[ $SITUATION == fresh ]] && die "--update: there's no metalgo here yet"
    # The L1s on the node now, and any asked for, less any being removed.
    read -r -a CHAINS <<<"$(parse_chain_list "$(installed_chains) ${CHAINS[*]:-}")"
    local c keep=()
    for c in ${CHAINS[@]+"${CHAINS[@]}"}; do [[ " ${REMOVE[*]:-} " == *" $c "* ]] || keep+=("$c"); done
    CHAINS=(${keep[@]+"${keep[@]}"})
    info "updating: ${CHAINS[*]:-no L1s}"
  fi

  case $SITUATION in
    fresh) log "Fresh server: a new Metal node (${MODE:-l1-only}), plus: ${CHAINS[*]:-no L1s}" ;;
    ours) log "A node metalgo-setup installed ($UNIT_NAME): bringing it up to date" ;;
    existing)
      show_node
      [[ -n $MODE ]] && warn "--mode applies only to a node metalgo-setup installs; $UNIT_NAME keeps its own settings"
      ((HARDEN_SSH)) && warn "--harden-ssh applies only to a fresh install; SSH left alone"
      ;;
  esac
  preflight

  if [[ $SITUATION == existing ]]; then
    check_existing
    node_role
    if ((IS_VALIDATOR)); then
      cat <<EOF
    This node validates the Metal primary network. Adding the L1s doesn't touch
    that: same staking key and NodeID, and every setting stays as it is apart
    from track-subnets. metalgo restarts once to load the plugins, which takes
    it offline for seconds; uptime counts over the whole staking period, so a
    restart doesn't put rewards at risk. Use --no-restart to pick the moment.
EOF
      ((PARTIAL_SYNC)) && warn "this validator syncs only the P-Chain (partial-sync-primary-network), which metalgo reports as unhealthy for a primary-network validator"
    fi
    if ((${#VALIDATES_L1[@]})); then
      info "It also validates: ${VALIDATES_L1[*]}. Those L1s pause while metalgo restarts."
    fi
    if ((${#CHAINS[@]})); then
      apt_install ca-certificates curl git build-essential jq openssl perl
    fi
    if ((${#CHAINS[@]} || ${#REMOVE[@]})); then
      # Before changing anything: can the new track-subnets be written?
      local want_now=()
      mapfile -t want_now < <(desired_tracked)
      if [[ "${want_now[*]:-}" != "${TRACKED[*]:-}" ]]; then
        tracked_writable "$(
          IFS=,
          printf '%s' "${want_now[*]:-}"
        )"
      fi
    fi
    if ((${#CHAINS[@]})) || [[ -n $(installed_chains) ]]; then
      workdir_guard
    fi
  else
    fresh_preflight
    fresh_packages
    fresh_user_and_dirs
    fresh_metalgo
    fresh_public_ip
    # The node's config takes the L1 subnets too, so it starts only once.
    local want=()
    mapfile -t want < <(desired_tracked)
    fresh_config "$(
      IFS=,
      printf '%s' "${want[*]:-}"
    )"
    TRACKED=(${want[@]+"${want[@]}"})
    fresh_unit
    [[ $SITUATION == fresh ]] && fresh_firewall
    fresh_auto_updates
    fresh_ssh
  fi

  if ((${#CHAINS[@]})); then
    build_tools
    local c
    for c in "${CHAINS[@]}"; do
      install_plugin "$c"
      chain_config "$c"
    done
  fi
  # Validator settings, for the chains being added and any chain named in
  # --mining-address that's already here.
  local vs
  for vs in $(parse_chain_list "${CHAINS[*]:-} $MINING_CHAINS"); do
    [[ " ${REMOVE[*]:-} " == *" $vs "* ]] && continue
    if [[ " ${CHAINS[*]:-} " != *" $vs "* && " $(installed_chains) " != *" $vs "* ]]; then
      die "--mining-address $vs: $(chain_var "$vs" TITLE) isn't on this node; add it with --chains $vs"
    fi
    validator_settings "$vs"
  done
  for c in ${REMOVE[@]+"${REMOVE[@]}"}; do remove_chain "$c"; done
  if ((${#CHAINS[@]} || ${#REMOVE[@]})); then
    local want=()
    mapfile -t want < <(desired_tracked)
    set_tracked ${want[@]+"${want[@]}"}
  fi
  if [[ $SITUATION == existing ]] && ((${#CHAINS[@]})); then
    killmode_dropin
  fi

  RESTARTED=1
  restart_node

  if ((TEST_ONLY)); then
    [[ $SITUATION != existing ]] && ! ((DRY_RUN)) && fresh_identity
    log "TEST MODE: done (no waiting, no network)"
    return 0
  fi
  if ((DRY_RUN)); then
    echo
    log "DRY RUN done: nothing was changed"
    return 0
  fi
  # The rest waits on the node.
  if wait_api 120; then
    ok "metalgo is up: $NODE_ID"
  else
    warn "metalgo's API ($NODE_API) isn't answering yet: journalctl -u $UNIT_NAME -n 50"
  fi
  [[ $SITUATION != existing ]] && fresh_identity
  local all=()
  read -r -a all <<<"$(installed_chains)"
  if ((${#all[@]})) && [[ -n $NODE_ID ]]; then
    local secs=$WAIT_SECS
    # A full node's first sync takes many hours; don't sit and wait for it.
    if [[ $SITUATION == fresh && $MODE == full ]] && ! ((WAIT_SET)); then secs=0; fi
    if ((RESTARTED && secs)); then wait_bootstrapped "$secs" "${all[@]}" || true; fi
    report_heights "${all[@]}"
  fi
  if ((${#all[@]})); then followers_note; fi
  [[ -n $BACKUP_DIR ]] && info "Every file changed was backed up first, under $BACKUP_DIR"
  echo
  log "Done. Check any time with: sudo ./setup.sh --status"
}

main
