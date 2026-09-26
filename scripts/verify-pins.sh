#!/usr/bin/env bash
# Checks every pin in lib/pins.sh against upstream, from a workstation:
# metalgo's tag resolves to its commit and its release tarball has its hash;
# each L1's commit is on its branch and builds the L1's VM ID. Needs git,
# curl, sha256sum or shasum, and Go.
# shellcheck disable=SC2015 # pass never fails, so A && pass || fail is if-then-else
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/pins.sh
source "$REPO_DIR/lib/pins.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { printf 'ok    %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  FAILED=1
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

got=$(git ls-remote "$METALGO_REPO" "refs/tags/$METALGO_VERSION^{}" | cut -f1)
[[ $got == "$METALGO_COMMIT" ]] && pass "metalgo $METALGO_VERSION is $METALGO_COMMIT" || fail "metalgo $METALGO_VERSION is ${got:-missing}, pinned $METALGO_COMMIT"
curl -fsSLo "$WORK/metalgo.tgz" "$METALGO_TARBALL_URL"
got=$(sha256 "$WORK/metalgo.tgz")
[[ $got == "$METALGO_TARBALL_SHA256" ]] && pass "metalgo tarball SHA-256" || fail "metalgo tarball SHA-256 is $got"
curl -fsSLo "$WORK/go.tgz" "$GO_URL"
got=$(sha256 "$WORK/go.tgz")
[[ $got == "$GO_SHA256" ]] && pass "Go $GO_VERSION SHA-256" || fail "Go $GO_VERSION SHA-256 is $got"

for c in $ALL_CHAINS; do
  repo=${c}_REPO branch=${c}_BRANCH commit=${c}_COMMIT vm=${c}_VM_ID
  git clone -q --branch "${!branch}" "${!repo}" "$WORK/$c"
  if git -C "$WORK/$c" merge-base --is-ancestor "${!commit}" "origin/${!branch}" 2>/dev/null; then
    pass "$c ${!commit} is on ${!branch}"
  else
    fail "$c ${!commit} is not on ${!branch}"
    continue
  fi
  git -C "$WORK/$c" -c advice.detachedHead=false checkout -q "${!commit}"
  got=$(cd "$WORK/$c" && go run ./scripts/vm-id-generator.go | tail -1)
  [[ $got == "${!vm}" ]] && pass "$c builds VM ${!vm}" || fail "$c builds VM $got, pinned ${!vm}"
done
exit "$FAILED"
