#!/usr/bin/env bash
# The L1 validator process end to end, on real servers and Metal mainnet,
# with throwaway test L1s (never the live BTCVM, LTCVM or DogecoinVM L1s):
#
#   test/cloud-validators.sh PHASE        (T=~/.metalgo-setup-test by default)
#
#   create     make the three test L1s, validated by server 1 (costs METAL)
#   old        server 1 runs today's deployed plugins for them; blocks flow
#   upgrade    server 1 moves to the validator-manager code and validatorAdmins
#   join       servers 2-N install the L1s with metalgo-setup and apply:
#              request -> approve (admin) -> register (payer) -> fees
#   traffic    payments on each L1; every validator builds blocks and is paid
#   remove     the admin removes the last server; it stops building; a top-up
#   status     metalgo-setup --status on every server
#   disable    end every test validator; unused METAL returns to the payer
#
# $T holds, on this machine only: hosts ("N IP REGION" lines), ssh.sh,
# payer.json and admin.json (P-Chain keys), keys/ (reserve and fee keys),
# genesis-CHAIN.json, the built *-l1 and chain CLIs, and the state written
# here. The servers only ever get public data and their own chain configs.
set -euo pipefail

T=${T:-$HOME/.metalgo-setup-test}
PHASE=${1:?phase: create|old|upgrade|join|traffic|remove|status|disable}
CHAINS=(btcvm ltcvm dogevm)
SERVERS=$(awk '{print $1}' "$T/hosts" | sort -n | tr '\n' ' ')
LAST=$(awk '{print $1}' "$T/hosts" | sort -n | tail -1)
S=$T/ssh.sh

# Per-chain names (functions, not associative arrays: bash 3.2 on macOS).
repo_of() { case $1 in btcvm) echo btcvm ;; ltcvm) echo ltc-vm ;; dogevm) echo dogecoin-vm ;; esac; }
base_of() { case $1 in btcvm) echo 65c203a ;; ltcvm) echo 1c5eaed ;; dogevm) echo a294177 ;; esac; } # deployed code
addr_key() { case $1 in dogevm) echo dogecoinvmAddress ;; *) echo "${1}Address" ;; esac; }
wif_key() { case $1 in dogevm) echo dogecoinvmWIF ;; *) echo "${1}WIF" ;; esac; }
amount_of() { case $1 in dogevm) echo 1 ;; *) echo 0.001 ;; esac; }
envp_of() { case $1 in btcvm) echo BTCVM ;; ltcvm) echo LTCVM ;; dogevm) echo DOGEVM ;; esac; }

log() { printf '\n==> %s\n' "$*" >&2; }
ok() { printf '    ok  %s\n' "$*" >&2; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
ip() { awk -v n="$1" '$1 == n {print $2}' "$T/hosts"; }
port() { echo $((19650 + $1)); }
uri() { echo "http://127.0.0.1:$(port "$1")"; }
chain_id() { jq -r .chainID "$T/chain-$1.json"; }
subnet_id() { jq -r .subnetID "$T/chain-$1.json"; }
admin_p() { jq -r .pChainAddress "$T/admin.json"; }
payer_p() { jq -r .pChainAddress "$T/payer.json"; }

# An SSH tunnel to each server's API (localhost-only on the server).
tunnel() {
  local n=$1
  curl -s -m 3 "$(uri "$n")/ext/health" >/dev/null 2>&1 && return 0
  ssh -i "$HOME/.ssh/pulsevm_dev" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
    -o UserKnownHostsFile="$T/known_hosts" -o ExitOnForwardFailure=yes -f -N \
    -L "$(port "$n"):127.0.0.1:9650" "root@$(ip "$n")"
}
for n in $SERVERS; do tunnel "$n"; done

commit_head() { git -C "$HOME/dev/$(repo_of "$1")" rev-parse feature/l1-validators; }

# pin N COMMIT ADMINS: points server N's metalgo-setup at the test L1s and
# the given commit of each VM (from the bundle in /srv/metalgo-setup-src).
pin() {
  local n=$1 which=$2 admins=$3 c commit sed=()
  for c in "${CHAINS[@]}"; do
    if [[ $which == base ]]; then commit=$(git -C "$HOME/dev/$(repo_of "$c")" rev-parse "$(base_of "$c")"); else commit=$(commit_head "$c"); fi
    sed+=(-e "s|^${c}_REPO=.*|${c}_REPO=/srv/metalgo-setup-src/$(repo_of "$c").git|"
      -e "s|^${c}_BRANCH=.*|${c}_BRANCH=feature/l1-validators|"
      -e "s|^${c}_COMMIT=.*|${c}_COMMIT=$commit|"
      -e "s|^${c}_CHAIN_ID=.*|${c}_CHAIN_ID=$(chain_id "$c")|"
      -e "s|^${c}_SUBNET_ID=.*|${c}_SUBNET_ID=$(subnet_id "$c")|"
      -e "s|^${c}_VALIDATOR_ADMINS=.*|${c}_VALIDATOR_ADMINS=\"$admins\"|")
  done
  "$S" "$n" "cd /root/metalgo-setup && git checkout -q lib/pins.sh 2>/dev/null; [ -f lib/pins.sh.orig ] || cp lib/pins.sh lib/pins.sh.orig; cp lib/pins.sh.orig lib/pins.sh && sed -i $(printf '%q ' "${sed[@]}") lib/pins.sh"
}

mining_flags() {
  local n=$1 c out=()
  for c in "${CHAINS[@]}"; do out+=(--mining-address "$c=$(jq -r ".$(addr_key "$c")" "$T/keys/$c-fees$n.json")"); done
  printf '%s ' "${out[@]}"
}

# The chain's RPC password on server 1 (a test chain; kept in $T).
rpc_pass_file() {
  local c=$1
  local f=$T/rpcpass-$c
  [[ -s $f ]] || "$S" 1 "jq -r .rpcPass /var/lib/metalgo/configs/chains/$(chain_id "$c")/config.json" >"$f"
  chmod 600 "$f"
  echo "$f"
}
rpc() { # rpc CHAIN METHOD PARAMS: the test L1's JSON-RPC, via server 1
  curl -s -m 20 -u "$1:$(cat "$(rpc_pass_file "$1")")" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" "$(uri 1)/ext/bc/$(chain_id "$1")/rpc"
}
height() { rpc "$1" getblockcount | jq -r '.result // 0'; }

bootstrapped() {
  curl -s -m 10 -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"$2\"}}" \
    "$(uri "$1")/ext/info" | grep -q '"isBootstrapped":true'
}
wait_for() {
  local secs=$1 what=$2
  shift 2
  for _ in $(seq "$secs"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "timed out waiting for $what"
}

pay() { # pay CHAIN COUNT: one payment per block, from the reserve
  local c=$1 k h to
  to=$(jq -r ".$(addr_key "$c")" "$T/keys/$c-reserve.json")
  for k in $(seq "$2"); do
    h=$(height "$c")
    for _ in $(seq 30); do
      env "$(envp_of "$c")_RPC=$(uri 1)/ext/bc/$(chain_id "$c")/rpc" "$(envp_of "$c")_RPC_USER=$c" \
        "$(envp_of "$c")_RPC_PASS=$(cat "$(rpc_pass_file "$c")")" "$(envp_of "$c")_NETWORK=mainnet" \
        "$T/$c" send -key "$(jq -r ".$(wif_key "$c")" "$T/keys/$c-reserve.json")" -to "$to" -amount "$(amount_of "$c")" >/dev/null 2>"$T/pay.err" && break
      sleep 2
    done
    for _ in $(seq 90); do [[ $(height "$c") -gt $h ]] && break; sleep 1; done
    [[ $(height "$c") -gt $h ]] || fail "$c: no block after payment $k: $(tail -1 "$T/pay.err")"
  done
}

builder_of() { # CHAIN HEIGHT: the server whose fee address the block pays (0: none)
  local c=$1 block addr n
  block=$(rpc "$c" getblock "[\"$(rpc "$c" getblockhash "[$2]" | jq -r .result)\", 2]")
  addr=$(jq -r '.result.rawtx[0].vout[] | select(.value > 0) | (.scriptPubKey.address // .scriptPubKey.addresses[0])' <<<"$block" | head -1)
  for n in $SERVERS; do
    [[ $addr == "$(jq -r ".$(addr_key "$c")" "$T/keys/$c-fees$n.json")" ]] && { echo "$n"; return; }
  done
  echo 0
}

L1() { echo -network-id 1 -chain-id "$(chain_id "$1")" -subnet-id "$(subnet_id "$1")"; }
validators() { # shellcheck disable=SC2046
  "$T/$1-l1" validators $(L1 "$1") -node-uri "$(uri 1)"
}

settling() {
  local attempt
  for attempt in $(seq 16); do
    "$@" 2>"$T/settling.err" && return 0
    if grep -qE "changed moments ago|failed verifying warp" "$T/settling.err"; then
      printf '    (validator set settling: retry %d)\n' "$attempt" >&2
      sleep 20
      continue
    fi
    cat "$T/settling.err" >&2
    return 1
  done
  fail "the validator set never settled"
}

join_one() { # CHAIN SERVER
  local c=$1 n=$2 reg=$T/registration-$1-$2.json
  [[ -f $T/registered-$c-$n.json ]] && { ok "$c: server $n already registered"; return; }
  "$T/$c-l1" request -node-uri "$(uri "$n")" -owner "$(payer_p)" >"$T/request-$c-$n.json"
  # shellcheck disable=SC2046
  # shellcheck disable=SC2329 # run through settling below
  approve_register() {
    "$T/$c-l1" approve $(L1 "$c") -node-uri "$(uri 1)" -request "$T/request-$c-$n.json" \
      -key "$T/admin.json" -rpc-user "$c" -rpc-pass-file "$(rpc_pass_file "$c")" >"$reg" || return 1
    "$T/$c-l1" register -registration "$reg" -key "$T/payer.json" -uri "$(uri 1)" -balance 1 >"$T/registered-$c-$n.json.tmp" &&
      mv "$T/registered-$c-$n.json.tmp" "$T/registered-$c-$n.json"
  }
  settling approve_register
  ok "$c: server $n ($(jq -r .nodeID "$reg")) registered: $(jq -r .txID "$T/registered-$c-$n.json")"
}

case $PHASE in
  create)
    log "Test L1s on Metal mainnet, validated by server 1"
    for c in "${CHAINS[@]}"; do
      [[ -f $T/chain-$c.json ]] && { ok "$c: exists ($(chain_id "$c"))"; continue; }
      # A subnet left by an earlier, failed attempt is reused (chain names
      # are letters and digits only).
      reuse=()
      [[ -s $T/subnet-$c ]] && reuse=(-subnet "$(cat "$T/subnet-$c")")
      "$T/$c-l1" create -key "$T/payer.json" -genesis "$T/genesis-$c.json" -node-uri "$(uri 1)" \
        -network-id 1 -validator-balance 2 -name "${c}test" ${reuse[@]+"${reuse[@]}"} >"$T/chain-$c.json.tmp" 2>"$T/create-$c.err" || {
        grep -o 'created subnet [A-Za-z0-9]*' "$T/create-$c.err" | awk '{print $3}' >"$T/subnet-$c" || true
        cat "$T/create-$c.err" >&2
        fail "$c: create failed"
      }
      mv "$T/chain-$c.json.tmp" "$T/chain-$c.json"
      ok "$c: chain $(chain_id "$c"), subnet $(subnet_id "$c")"
    done
    ;;
  old)
    log "Server 1 runs today's deployed plugins for the test L1s"
    pin 1 base ""
    # shellcheck disable=SC2046
    "$S" 1 "cd /root/metalgo-setup && ./setup.sh --chains all --rpc $(mining_flags 1) --yes --wait 900" | tail -25
    for c in "${CHAINS[@]}"; do pay "$c" 3; ok "$c: blocks flow on the old code (height $(height "$c"))"; done
    ;;
  upgrade)
    log "Server 1: validator-manager code and validatorAdmins, as the live validators will get them"
    pin 1 head "$(admin_p)"
    "$S" 1 "cd /root/metalgo-setup && ./setup.sh --update --yes --wait 900" | tail -25
    for c in "${CHAINS[@]}"; do
      "$S" 1 "grep -h 'validator manager ready' /var/lib/metalgo/logs/*.log | grep $(chain_id "$c") | tail -1" | grep -qE '"validatorAdmins": ?1' ||
        fail "$c: server 1 didn't load its validatorAdmins"
      pay "$c" 3
      ok "$c: upgraded, validatorAdmins loaded, blocks still flow (height $(height "$c"))"
    done
    ;;
  join)
    log "Servers 2-$LAST install the test L1s with metalgo-setup"
    for n in $SERVERS; do
      ((n == 1)) && continue
      (
        pin "$n" head "$(admin_p)"
        # shellcheck disable=SC2046
        "$S" "$n" "cd /root/metalgo-setup && ./setup.sh --chains all --rpc $(mining_flags "$n") --yes --wait 900" >"$T/join-install-$n.log" 2>&1
      ) &
    done
    wait
    for n in $SERVERS; do
      ((n == 1)) && continue
      for c in "${CHAINS[@]}"; do wait_for 900 "server $n to bootstrap $c" bootstrapped "$n" "$(chain_id "$c")"; done
      ok "server $n follows all three test L1s"
    done
    log "Each server applies to each L1; the admin approves; the payer registers"
    for c in "${CHAINS[@]}"; do
      (
        for n in $SERVERS; do ((n == 1)) || join_one "$c" "$n"; done
      ) >"$T/join-$c.log" 2>&1 &
    done
    wait
    for c in "${CHAINS[@]}"; do
      cat "$T/join-$c.log"
      count=$(validators "$c" | jq length)
      [[ $count == "$LAST" ]] || fail "$c: $count validators, want $LAST"
      ok "$c: $count validators"
    done
    ;;
  traffic)
    for c in "${CHAINS[@]}"; do
      log "$c: payments; each validator builds blocks and is paid"
      first=$(($(height "$c") + 1))
      pay "$c" 40
      last=$(height "$c")
      built=(0 0 0 0 0 0 0 0 0 0) # by server number; 0: paid to no server
      for h in $(seq "$first" "$last"); do
        b=$(builder_of "$c" "$h")
        built[b]=$((built[b] + 1))
      done
      line=""
      for n in $SERVERS; do line+="server $n: ${built[n]}  "; done
      printf '    blocks %d-%d paid to %s(none: %d)\n' "$first" "$last" "$line" "${built[0]}" >&2
      for n in $SERVERS; do ((built[n] > 0)) || printf '    note: server %d built none of these %d blocks\n' "$n" $((last - first + 1)) >&2; done
    done
    ;;
  remove)
    for c in "${CHAINS[@]}"; do
      log "$c: the admin removes server $LAST"
      vid=$(jq -r .validationID "$T/registration-$c-$LAST.json")
      # shellcheck disable=SC2046
      settling "$T/$c-l1" remove $(L1 "$c") -node-uri "$(uri 1)" -validation-id "$vid" -key "$T/admin.json" \
        -payer-key "$T/payer.json" -rpc-user "$c" -rpc-pass-file "$(rpc_pass_file "$c")" >/dev/null
      nid=$(jq -r .nodeID "$T/registration-$c-$LAST.json")
      wait_for 120 "$nid off $c's validators" bash -c "! '$T/$c-l1' validators $(L1 "$c") -node-uri '$(uri 1)' | jq -e --arg n '$nid' 'map(.nodeID) | index(\$n)' >/dev/null"
      ok "$c: server $LAST removed"
      pay "$c" 3
      sleep 120
      first=$(($(height "$c") + 1))
      pay "$c" 15
      for h in $(seq "$first" "$(height "$c")"); do
        [[ $(builder_of "$c" "$h") != "$LAST" ]] || fail "$c: removed server $LAST built block $h"
      done
      ok "$c: server $LAST built none of the next 15 blocks"
      "$T/$c-l1" top-up -validation-id "$(jq -r .validationID "$T/registration-$c-2.json")" -key "$T/payer.json" \
        -uri "$(uri 1)" -balance 0.5 >/dev/null
      ok "$c: topped up server 2 by 0.5 METAL"
    done
    ;;
  status)
    for n in $SERVERS; do
      log "server $n: setup.sh --status"
      "$S" "$n" "cd /root/metalgo-setup && ./setup.sh --status" | sed -n '/Validating the L1s/,$p'
    done
    ;;
  disable)
    for c in "${CHAINS[@]}"; do
      log "$c: disable the test validators (unused METAL back to the payer)"
      validators "$c" | jq -r '.[].validationID' | while read -r vid; do
        [[ -n $vid ]] || continue
        "$T/$c-l1" disable -validation-id "$vid" -key "$T/payer.json" -uri "$(uri 1)" >/dev/null && ok "$c: disabled $vid"
      done
    done
    ;;
  *) fail "unknown phase $PHASE" ;;
esac
log "phase $PHASE done"
