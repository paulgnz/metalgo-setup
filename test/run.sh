#!/usr/bin/env bash
# Tests setup.sh in throwaway ubuntu:24.04 (x86_64) containers, one per
# scenario, with fake systemctl, ufw and metalgo (test/fakes) and TEST MODE
# (METALGO_SETUP_TEST_ONLY=1: nothing downloaded or built, no network):
#
#   test/run.sh                 every scenario
#   test/run.sh SCENARIO...     just those
#
# Needs docker with linux/amd64 (native or emulated). Logs go to test/out/.
# shellcheck disable=SC2016 # single-quoted jq programs and inner shells
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=$HERE/out
IMAGE=metalgo-setup-test
SCENARIOS=(fresh-l1-only fresh-full flags-unit config-file-unit defaults-unit refusals config-file-options validator-settings workdir-guard own-metalgo-unit)
mkdir -p "$OUT"

docker build -q --platform linux/amd64 -t "$IMAGE" "$HERE" >/dev/null
DOCKER=(docker run --rm --platform linux/amd64 -v "$REPO:/src:ro" "$IMAGE")

FAILED=0
# bash -n with the bash setup.sh runs under (Ubuntu 24.04's).
if "${DOCKER[@]}" bash -c 'for f in /src/setup.sh /src/lib/*.sh /src/test/*.sh /src/test/fakes/systemctl; do bash -n "$f" || exit 1; done' >"$OUT/bash-n.log" 2>&1; then
  echo "PASS  bash -n (bash $("${DOCKER[@]}" bash -c 'echo $BASH_VERSION'))"
else
  echo "FAIL  bash -n (log $OUT/bash-n.log)"
  FAILED=1
fi

for s in "${@:-${SCENARIOS[@]}}"; do
  log=$OUT/$s.log
  if "${DOCKER[@]}" bash /src/test/in-container.sh "$s" >"$log" 2>&1; then
    echo "PASS  $s ($(grep -c '^ok ' "$log") checks)"
  else
    echo "FAIL  $s (log $log; tail below)"
    tail -30 "$log"
    FAILED=1
  fi
done
exit "$FAILED"
