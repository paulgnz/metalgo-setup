# shellcheck shell=bash disable=SC2034 # its variables are used by setup.sh and the other libs
# Finds an existing metalgo service and works out its settings the way
# metalgo v1.13.5 itself does (config/flags.go, config/viper.go,
# config/config.go):
#
#   a flag on the command line > an AVAGO_* environment variable (viper's
#   AutomaticEnv, prefix "avago", dashes as underscores) > the config file
#   (--config-file, or the base64 --config-file-content) > the default.
#
# Defaults: data-dir $HOME/.metalgo; plugin-dir, chain-config-dir and log-dir
# under $METALGO_DATA_DIR (which expands to the data dir): plugins,
# configs/chains, logs. network-id mainnet. track-subnets empty. Paths expand
# $VARS from the service's environment, and relative paths are relative to
# its working directory.
#
# Sourced by setup.sh; not run on its own.

# metalgo's boolean flags (fs.Bool in config/flags.go, v1.13.5): pflag gives
# these no separate value, so "--flag value" is two arguments for these only.
METALGO_BOOL_FLAGS=' api-admin-enabled api-health-enabled api-info-enabled api-metrics-enabled
  db-read-only http-tls-enabled index-allow-incomplete index-enabled log-disable-display-plugin-logs
  log-rotater-compress-enabled meter-vms-enabled network-allow-private-ips
  network-require-validator-to-connect network-tcp-proxy-enabled partial-sync-primary-network
  profile-continuous-enabled proposervm-use-current-height staking-ephemeral-cert-enabled
  staking-ephemeral-signer-enabled sybil-protection-enabled tracing-insecure version version-json '
METALGO_BOOL_FLAGS=${METALGO_BOOL_FLAGS//$'\n'/ }

# Marks files this installer manages.
MANAGED_MARK='Managed by metalgo-setup'

# split_words STRING: systemd-style word splitting (quotes, backslashes) into
# the array WORDS.
# shellcheck disable=SC1003 # a lone backslash is what these match
split_words() {
  local s=$1 i n=${#1} c w='' inword=0 q=''
  WORDS=()
  for ((i = 0; i < n; i++)); do
    c=${s:i:1}
    if [[ -n $q ]]; then
      if [[ $c == "$q" ]]; then
        q=''
      elif [[ $c == '\' && $q == '"' ]] && ((i + 1 < n)); then
        i=$((i + 1))
        w+=${s:i:1}
      else
        w+=$c
      fi
      continue
    fi
    case $c in
      ' ' | $'\t' | $'\n')
        if ((inword)); then
          WORDS+=("$w")
          w='' inword=0
        fi
        ;;
      '"' | "'") q=$c inword=1 ;;
      '\')
        i=$((i + 1))
        w+=${s:i:1}
        inword=1
        ;;
      *) w+=$c inword=1 ;;
    esac
  done
  ((inword)) && WORDS+=("$w")
  return 0
}

# find_metalgo_units: prints the name of every systemd service whose
# ExecStart runs a binary called metalgo, one per line.
find_metalgo_units() {
  local d f
  for d in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    [[ -d $d ]] || continue
    for f in "$d"/*.service "$d"/*.service.d/*.conf; do
      [[ -f $f ]] || continue
      if grep -qE '^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*[-@:+!]*([^[:space:]]*/)?metalgo([[:space:]]|$)' "$f"; then
        f=${f#"$d"/}
        f=${f%%.service*}
        printf '%s\n' "$f"
      fi
    done
  done | sort -u
}

# read_unit NAME: reads the unit and its drop-ins (systemctl cat) into
# UNIT_* variables.
read_unit() {
  local unit=$1 text line joined='' file='' section='' key val
  text=$(systemctl cat -- "$unit.service" 2>/dev/null) || die "no systemd service called $unit (systemctl cat $unit.service failed)"
  UNIT_NAME=$unit UNIT_EXEC='' UNIT_EXEC_FILE='' UNIT_USER='' UNIT_GROUP='' UNIT_WORKDIR=''
  UNIT_KILLMODE='' UNIT_TIMEOUT_STOP='' UNIT_DYNAMIC_USER='' UNIT_FILES=() UNIT_ENV_ASSIGN=() UNIT_ENV_FILES=()
  UNIT_MANAGED=0
  [[ $text == *"$MANAGED_MARK"* ]] && UNIT_MANAGED=1
  while IFS= read -r line || [[ -n $line ]]; do
    # "systemctl cat" heads each file with "# /path/to/file".
    if [[ -z $joined && $line =~ ^\#\ (/[^[:space:]]+)$ ]]; then
      file=${BASH_REMATCH[1]}
      UNIT_FILES+=("$file")
      section=''
      continue
    fi
    # A trailing backslash continues the line.
    if [[ $line == *\\ ]]; then
      joined+="${line%\\} "
      continue
    fi
    line=$joined$line
    joined=''
    [[ $line =~ ^[[:space:]]*([#\;]|$) ]] && continue
    if [[ $line =~ ^[[:space:]]*\[([A-Za-z]+)\][[:space:]]*$ ]]; then
      section=${BASH_REMATCH[1]}
      continue
    fi
    [[ $section == Service ]] || continue
    [[ $line =~ ^[[:space:]]*([A-Za-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    val=${val%"${val##*[![:space:]]}"}
    case $key in
      ExecStart)
        if [[ -z $val ]]; then
          UNIT_EXEC='' UNIT_EXEC_FILE=''
        else
          UNIT_EXEC=$val UNIT_EXEC_FILE=$file
        fi
        ;;
      User) UNIT_USER=$val ;;
      Group) UNIT_GROUP=$val ;;
      DynamicUser) UNIT_DYNAMIC_USER=$val ;;
      WorkingDirectory) UNIT_WORKDIR=$val ;;
      KillMode) UNIT_KILLMODE=$val ;;
      TimeoutStopSec | TimeoutSec) UNIT_TIMEOUT_STOP=$val ;;
      Environment)
        if [[ -z $val ]]; then UNIT_ENV_ASSIGN=(); else
          split_words "$val"
          UNIT_ENV_ASSIGN+=("${WORDS[@]}")
        fi
        ;;
      EnvironmentFile)
        if [[ -z $val ]]; then UNIT_ENV_FILES=(); else UNIT_ENV_FILES+=("$val"); fi
        ;;
    esac
  done <<<"$text"
  [[ -n $UNIT_EXEC ]] || die "$unit.service has no ExecStart"
  case ${UNIT_DYNAMIC_USER,,} in
    yes | true | 1 | on) die "$unit.service uses DynamicUser=; metalgo-setup can't tell where its files live" ;;
  esac
}

# unit_environment: fills UENV (name -> value) with what systemd gives the
# service: USER/HOME from User=, then Environment=, then EnvironmentFile=.
declare -A UENV
unit_environment() {
  local a f optional line k v pw
  UENV=()
  local explicit_user=$UNIT_USER
  UNIT_USER=${UNIT_USER:-root}
  pw=$(getent passwd "$UNIT_USER" || true)
  [[ -n $pw ]] || die "$UNIT_NAME.service runs as $UNIT_USER, which is not a user on this machine"
  UNIT_UID=$(cut -d: -f3 <<<"$pw")
  if [[ -z $UNIT_GROUP ]]; then
    UNIT_GROUP=$(id -gn "$UNIT_USER")
  fi
  # systemd sets these when User= is set (systemd.exec(5)); for a root
  # service without User=, metalgo sees whatever HOME it is given below.
  UENV[USER]=$UNIT_USER UENV[LOGNAME]=$UNIT_USER
  if [[ -n $explicit_user ]]; then
    UENV[HOME]=$(cut -d: -f6 <<<"$pw")
  fi
  for a in ${UNIT_ENV_ASSIGN[@]+"${UNIT_ENV_ASSIGN[@]}"}; do
    [[ $a == *=* ]] && UENV[${a%%=*}]=${a#*=}
  done
  for f in ${UNIT_ENV_FILES[@]+"${UNIT_ENV_FILES[@]}"}; do
    optional=0
    [[ $f == -* ]] && optional=1 f=${f#-}
    if [[ ! -r $f ]]; then
      ((optional)) || warn "$UNIT_NAME.service reads $f, which is missing"
      continue
    fi
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*(#|\;|$) ]] && continue
      [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
      k=${BASH_REMATCH[2]} v=${BASH_REMATCH[3]}
      split_words "$v"
      UENV[$k]=${WORDS[*]:-}
    done <"$f"
  done
  # The running process's HOME is the ground truth, if it is running.
  local pid
  pid=$(systemctl show -p MainPID --value -- "$UNIT_NAME.service" 2>/dev/null || true)
  if [[ ${pid:-0} != 0 && -r /proc/$pid/environ ]]; then
    v=$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^HOME=//p' | head -1)
    [[ -n $v ]] && UENV[HOME]=$v
  fi
  UNIT_PID=${pid:-0}
}

# expand_env STRING: expands $VAR and ${VAR} from UENV, as Go's os.ExpandEnv
# would inside the service. METALGO_DATA_DIR becomes the data dir, as in
# metalgo's getExpandedArg (EXPAND_DATA_DIR holds it).
EXPAND_DATA_DIR=''
expand_env() {
  local s=$1 out='' name
  while [[ $s =~ ^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$ ]]; do
    out+=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    if [[ $name == METALGO_DATA_DIR && -n $EXPAND_DATA_DIR ]]; then
      out+=$EXPAND_DATA_DIR
    else
      out+=${UENV[$name]:-}
    fi
    s=${BASH_REMATCH[5]}
  done
  printf '%s' "$out$s"
}

# systemd's own expansion of an ExecStart word: specifiers (%h, %u, %n, %%)
# and ${VAR} from the unit's environment.
expand_exec_word() {
  local w=$1
  w=${w//%%/$'\x01'}
  w=${w//%h/${UENV[HOME]:-/root}}
  w=${w//%u/$UNIT_USER}
  w=${w//%n/$UNIT_NAME.service}
  w=${w//%N/$UNIT_NAME}
  w=${w//$'\x01'/%}
  expand_env "$w"
}

# abs_path PATH: relative paths are relative to the working directory.
abs_path() {
  local p=$1
  [[ $p == /* || -z $p ]] && { printf '%s' "$p"; return; }
  printf '%s/%s' "$(unit_workdir)" "$p"
}

# unit_workdir: the service's working directory ("/" unless set).
unit_workdir() {
  local wd=${UNIT_WORKDIR:-/}
  wd=${wd#-}
  [[ $wd == '~' ]] && wd=${UENV[HOME]:-/}
  wd=${wd%/}
  printf '%s' "${wd:-/}"
}

# relative_paths: 1 if any path-like setting (a *-dir or *-file flag or
# config key) is relative, so moving the working directory would move it.
relative_paths() {
  local k v
  for k in "${!FLAGS[@]}"; do
    [[ $k == *-dir || $k == *-file ]] || continue
    v=${FLAGS[$k]}
    [[ -n $v && $v != /* && $v != '$'* ]] && { echo 1; return; }
  done
  jq -r 'to_entries[] | select(.key | test("-(dir|file)$"; "i")) | .value | strings' <<<"$CFG_JSON" 2>/dev/null |
    grep -qvE '^(/|\$|$)' && { echo 1; return; }
  echo 0
}

# parse_exec: splits ExecStart into NODE_BIN and FLAGS (name -> value, the
# last one winning, as with pflag).
declare -A FLAGS
parse_exec() {
  local words=() i w k
  FLAGS=()
  split_words "$UNIT_EXEC"
  words=("${WORDS[@]}")
  ((${#words[@]})) || die "$UNIT_NAME.service: empty ExecStart"
  w=${words[0]}
  UNIT_EXEC_ARGV0=0
  while [[ $w == [-@:+!]* ]]; do
    [[ $w == @* ]] && UNIT_EXEC_ARGV0=1
    w=${w:1}
  done
  NODE_BIN=$(expand_exec_word "$w")
  i=1
  # With "@", the next word is argv[0], not an argument.
  ((UNIT_EXEC_ARGV0)) && i=2
  if [[ $NODE_BIN != /* ]]; then
    NODE_BIN=$(command -v "$NODE_BIN" || true)
  fi
  [[ -n $NODE_BIN && $(basename "$NODE_BIN") == metalgo ]] ||
    die "$UNIT_NAME.service starts ${w}, not a metalgo binary. If metalgo runs through a wrapper script, metalgo-setup can't read its settings."
  for (( ; i < ${#words[@]}; i++)); do
    w=$(expand_exec_word "${words[i]}")
    case $w in
      --*=*)
        k=${w%%=*}
        FLAGS[${k#--}]=${w#*=}
        ;;
      --*)
        k=${w#--}
        if [[ $METALGO_BOOL_FLAGS == *" $k "* ]]; then
          FLAGS[$k]=true
        elif ((i + 1 < ${#words[@]})); then
          i=$((i + 1))
          FLAGS[$k]=$(expand_exec_word "${words[i]}")
        else
          die "$UNIT_NAME.service: --$k has no value"
        fi
        ;;
      -*) warn "$UNIT_NAME.service: ignoring '$w' (metalgo takes --flags)" ;;
    esac
  done
}

# The config file's contents as JSON (CFG_JSON), whatever its format.
load_config_file() {
  CFG_FILE='' CFG_TYPE='' CFG_JSON='{}' CFG_SRC=''
  local content_type b64
  b64=${FLAGS[config-file-content]:-${UENV[AVAGO_CONFIG_FILE_CONTENT]:-}}
  if [[ -n $b64 ]]; then
    CFG_SRC=content
    content_type=${FLAGS[config-file-content-type]:-${UENV[AVAGO_CONFIG_FILE_CONTENT_TYPE]:-json}}
    [[ ${content_type,,} == json ]] || die "$UNIT_NAME.service passes its config as base64 $content_type (--config-file-content); metalgo-setup reads only JSON there"
    CFG_JSON=$(base64 -d <<<"$b64" | jq -c .) || die "can't decode $UNIT_NAME.service's --config-file-content"
    return
  fi
  local f=${FLAGS[config-file]:-${UENV[AVAGO_CONFIG_FILE]:-}}
  [[ -n $f ]] || return 0
  # metalgo expands the config file's path with the data dir given by flag,
  # environment or default (the config file itself isn't read yet).
  EXPAND_DATA_DIR=$(abs_path "$(expand_env "${FLAGS[data-dir]:-${UENV[AVAGO_DATA_DIR]:-\$HOME/.metalgo}}")")
  f=$(abs_path "$(expand_env "$f")")
  [[ -r $f ]] || die "$UNIT_NAME.service uses the config file $f, which can't be read"
  CFG_FILE=$f CFG_SRC=file
  case ${f,,} in
    *.json) CFG_TYPE=json ;;
    *.yaml | *.yml) CFG_TYPE=yaml ;;
    *.toml) CFG_TYPE=toml ;;
    *) CFG_TYPE=json ;;
  esac
  if [[ $CFG_TYPE == json ]]; then
    CFG_JSON=$(jq -c . "$f") || die "$f is not valid JSON"
    [[ $(jq -r type <<<"$CFG_JSON") == object ]] || die "$f is not a JSON object"
  else
    # Flat "key: value" / "key = value" lines are all metalgo's config has.
    CFG_JSON=$(sed -nE 's/^[[:space:]]*([A-Za-z0-9-]+)[[:space:]]*[:=][[:space:]]*"?([^"#]*[^"#[:space:]])?"?[[:space:]]*(#.*)?$/\1\t\2/p' "$f" |
      jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] // "")}] | add // {}')
  fi
}

# setting KEY DEFAULT: the effective value of a metalgo setting (not yet
# expanded), and where it came from in SETTING_SRC: flag, env, config or
# default.
setting() {
  local key=$1 def=$2 env v
  env=AVAGO_$(tr 'a-z-' 'A-Z_' <<<"$key")
  if [[ -v FLAGS[$key] ]]; then
    SETTING_SRC=flag
    printf '%s' "${FLAGS[$key]}"
  elif [[ -v UENV[$env] ]]; then
    SETTING_SRC='env'
    printf '%s' "${UENV[$env]}"
  elif v=$(jq -er --arg k "$key" 'to_entries | map(select((.key | ascii_downcase) == $k)) | last | select(. != null) | .value
        | if type == "string" then . elif type == "array" then error("array") else tojson end' <<<"$CFG_JSON" 2>/dev/null); then
    SETTING_SRC=config
    printf '%s' "$v"
  else
    SETTING_SRC=default
    printf '%s' "$def"
  fi
}
# setting_src KEY: where KEY comes from (SETTING_SRC is lost in $(...)).
setting_src() {
  setting "$1" '' >/dev/null
  printf '%s' "$SETTING_SRC"
}

# is_true VALUE: as Go's strconv.ParseBool.
is_true() { [[ ${1,,} =~ ^(1|t|true)$ ]]; }

# resolve_node: from the unit, every setting metalgo-setup needs.
# shellcheck disable=SC2016 # the defaults are expanded later, as metalgo does
resolve_node() {
  local v
  unit_environment
  parse_exec
  load_config_file

  v=$(setting data-dir '$HOME/.metalgo')
  DATA_DIR=$(abs_path "$(expand_env "$v")")
  [[ $DATA_DIR == /* && $DATA_DIR != / ]] || die "can't tell $UNIT_NAME.service's data dir (data-dir resolves to '$DATA_DIR')"
  EXPAND_DATA_DIR=$DATA_DIR

  v=$(setting plugin-dir '$METALGO_DATA_DIR/plugins')
  PLUGIN_DIR=$(abs_path "$(expand_env "$v")")
  v=$(setting chain-config-dir '$METALGO_DATA_DIR/configs/chains')
  CHAIN_CONFIG_DIR=$(abs_path "$(expand_env "$v")")
  if [[ -n $(setting chain-config-content '') ]]; then
    die "$UNIT_NAME.service passes chain configs as base64 (--chain-config-content), so metalgo ignores the chain config directory; metalgo-setup can't add chain configs to it"
  fi

  NETWORK=$(setting network-id mainnet)
  v=$(setting track-subnets '')
  TRACK_SRC=$(setting_src track-subnets)
  [[ $TRACK_SRC == config && $CFG_SRC == content ]] && TRACK_SRC=content
  TRACKED=()
  local s
  for s in ${v//,/ }; do TRACKED+=("$s"); done

  REL_PATHS=$(relative_paths)

  PARTIAL_SYNC=0
  is_true "$(setting partial-sync-primary-network false)" && PARTIAL_SYNC=1

  local host port scheme=http
  host=$(setting http-host 127.0.0.1)
  port=$(setting http-port 9650)
  is_true "$(setting http-tls-enabled false)" && scheme=https
  case $host in '' | 0.0.0.0 | '::' | '[::]') host=127.0.0.1 ;; esac
  [[ $host == *:* && $host != \[* ]] && host="[$host]"
  NODE_API=$scheme://$host:$port
  CURL_TLS=()
  [[ $scheme == https ]] && CURL_TLS=(-k)
  return 0
}

# network_is_mainnet VALUE: as metalgo's GetNetworkID parses it.
network_is_mainnet() {
  case ${1,,} in mainnet | 1 | network-1) return 0 ;; esac
  return 1
}

# metalgo_version BIN: its --version line.
metalgo_version() {
  "$1" --version 2>/dev/null | head -1
}

# is_tracked SUBNET
is_tracked() {
  local s
  for s in ${TRACKED[@]+"${TRACKED[@]}"}; do [[ $s == "$1" ]] && return 0; done
  return 1
}

# --- The node's API ------------------------------------------------------------
# node_call ENDPOINT METHOD [PARAMS]: a JSON-RPC call to the node's own API.
node_call() {
  local endpoint=$1 method=$2 params=${3:-'{}'}
  curl -s -m 10 ${CURL_TLS[@]+"${CURL_TLS[@]}"} -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "$NODE_API/ext/$endpoint" 2>/dev/null
}

node_id() {
  node_call info info.getNodeID | jq -r '.result.nodeID // empty' 2>/dev/null || true
}

# is_bootstrapped CHAIN: true, false, or empty if the node doesn't know it.
is_bootstrapped() {
  node_call info info.isBootstrapped "{\"chain\":\"$1\"}" | jq -r '.result.isBootstrapped // empty | tostring' 2>/dev/null || true
}

# validates NODEID [SUBNET]: whether the node is a current validator of the
# primary network, or of SUBNET's L1. Empty if the P-Chain can't say.
validates() {
  local params
  if [[ -n ${2:-} ]]; then
    params="{\"subnetID\":\"$2\",\"nodeIDs\":[\"$1\"]}"
  else
    params="{\"nodeIDs\":[\"$1\"]}"
  fi
  node_call bc/P platform.getCurrentValidators "$params" |
    jq -r 'if .result.validators then (.result.validators | length > 0 | tostring) else empty end' 2>/dev/null || true
}
