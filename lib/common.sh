# shellcheck shell=bash disable=SC2034 # its variables are used by setup.sh and the other libs
# Output, dry runs, file writes with backups, and the build user's commands.
# Sourced by setup.sh; not run on its own.

# --- Fixed places ---------------------------------------------------------------
STATE_DIR=/var/lib/metalgo-setup            # build stamps (root only)
BACKUP_ROOT=/var/backups/metalgo-setup      # a copy of every file changed
DL_DIR=/var/cache/metalgo-setup             # downloads (root only, never /tmp)
TOOLS_DIR=/opt/metalgo-setup                # our own Go; never /usr/local/go
GO_ROOT=$TOOLS_DIR/go$GO_VERSION
BUILD_USER=metalgo-build                    # builds run as this user, never root
BUILD_HOME=/var/lib/metalgo-build

# --- Output ------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD='' RED='' GREEN='' YELLOW='' RESET=''
fi
log() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %sok%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

# --- Doing, or printing in a dry run ----------------------------------------------
DRY_RUN=${DRY_RUN:-0}
# TEST ONLY: set by the container tests. Skips downloads, builds, apt, the
# firewall and network calls, and puts stand-ins where binaries go. Never set
# it on a real server: the result can't run anything.
TEST_ONLY=${METALGO_SETUP_TEST_ONLY:-0}

quote() {
  local out=() a
  for a in "$@"; do out+=("$(printf '%q' "$a")"); done
  printf '%s' "${out[*]}"
}

# run CMD...: runs it, or prints it in a dry run.
run() {
  if ((DRY_RUN)); then
    printf '    + %s\n' "$(quote "$@")"
  else
    "$@"
  fi
}

# One backup directory per run, made on first use.
BACKUP_DIR=''
# backup PATH: copies PATH (a file or directory) into this run's backup
# directory, keeping its full path, owner and mode. Nothing to do if absent.
backup() {
  local path=$1
  [[ -e $path ]] || return 0
  if [[ -z $BACKUP_DIR ]]; then
    BACKUP_DIR=$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$
    if ((DRY_RUN)); then
      printf '    + back up changed files under %s\n' "$BACKUP_DIR"
    else
      install -d -m 0700 -o root -g root "$BACKUP_ROOT" "$BACKUP_DIR"
    fi
  fi
  if ((DRY_RUN)); then
    printf '    + back up %s\n' "$path"
    return
  fi
  mkdir -p "$BACKUP_DIR$(dirname "$path")"
  cp -a "$path" "$BACKUP_DIR$path"
}

# write_file PATH MODE OWNER:GROUP < CONTENT
# Writes atomically and only if something differs, backing up the old file
# first. Sets FILE_CHANGED. New files are made with umask 077 before chmod, so
# a secret is never readable by others even for a moment. In a dry run the
# content is shown, unless it is marked secret (SECRET_CONTENT=1).
FILE_CHANGED=0
SECRET_CONTENT=0
write_file() {
  local path=$1 mode=$2 owner=$3 content tmp
  content=$(
    cat
    printf x
  )
  content=${content%x}
  FILE_CHANGED=0
  if [[ -f $path ]] && [[ "$(stat -c '%a %U:%G' "$path" 2>/dev/null)" == "${mode#0} $owner" ]] &&
    printf '%s' "$content" | cmp -s - "$path"; then
    return 0
  fi
  FILE_CHANGED=1
  if ((DRY_RUN)); then
    backup "$path"
    printf '    + write %s (mode %s, owner %s)%s\n' "$path" "$mode" "$owner" "$([[ -f $path ]] && echo ', replacing the current file')"
    if ((SECRET_CONTENT)); then
      printf '    |   (holds a password: not shown)\n'
    elif [[ -f $path ]] && command -v diff >/dev/null; then
      diff -u "$path" <(printf '%s' "$content") | sed -n '3,$p' | sed 's/^/    |   /' || true
    else
      printf '%s' "$content" | sed 's/^/    |   /'
    fi
    return 0
  fi
  backup "$path"
  tmp=$(umask 077 && mktemp "$(dirname "$path")/.metalgo-setup.XXXXXX")
  printf '%s' "$content" >"$tmp"
  chown "$owner" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

# remove_path PATH: backs it up, then removes it.
remove_path() {
  local path=$1
  [[ -e $path ]] || return 0
  backup "$path"
  run rm -rf -- "$path"
}

# A new random password (never printed). In a dry run, a placeholder.
new_secret() {
  if ((DRY_RUN)); then
    printf 'DRY-RUN-PLACEHOLDER'
  else
    openssl rand -hex 24
  fi
}

# verify_sha256 FILE HASH: stops unless FILE has that SHA-256.
verify_sha256() {
  if ((DRY_RUN)); then
    printf '    + check that the SHA-256 of %s is %s\n' "$1" "$2"
  else
    echo "$2  $1" | sha256sum -c --quiet - || die "$1 does not match its pinned SHA-256; not installing it"
  fi
}

# yes_no QUESTION DEFAULT(y|n): asks on the terminal.
yes_no() {
  local q=$1 def=$2 a hint='[y/N]'
  [[ $def == y ]] && hint='[Y/n]'
  while true; do
    read -r -p "$q $hint " a </dev/tty || a=''
    a=${a:-$def}
    case ${a,,} in
      y | yes) return 0 ;;
      n | no) return 1 ;;
    esac
  done
}

# --- The build user -------------------------------------------------------------
# Go from our own pinned tree, never a downloaded toolchain, and caches in the
# build user's home. CGO_CFLAGS passes through: on a CPU without ADX/BMI2
# (very old x86_64, or an emulator), metalgo's BLS library (blst) needs
# CGO_CFLAGS="-O -D__BLST_PORTABLE__", or it dies with SIGILL.
build_env() {
  runuser -u "$BUILD_USER" -- env -i HOME="$BUILD_HOME" PATH="$GO_ROOT/bin:/usr/bin:/bin" \
    GOROOT="$GO_ROOT" GOTOOLCHAIN=local GOPATH="$BUILD_HOME/go" GOCACHE="$BUILD_HOME/.cache/go-build" \
    GOFLAGS=-mod=readonly ${CGO_CFLAGS:+CGO_CFLAGS="$CGO_CFLAGS"} "$@"
}
as_build() {
  if ((DRY_RUN)); then
    printf '    + [as %s] %s\n' "$BUILD_USER" "$(quote "$@")"
  else
    build_env "$@"
  fi
}
# build_in DIR CMD...: runs CMD in DIR as the build user.
build_in() {
  local dir=$1
  shift
  if ((DRY_RUN)); then
    printf '    + [as %s, in %s] %s\n' "$BUILD_USER" "$dir" "$(quote "$@")"
  else
    # shellcheck disable=SC2016 # $1 and $@ belong to the inner shell
    build_env bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
  fi
}

# checkout_pinned DIR REPO REF COMMIT: DIR holds REPO at exactly COMMIT, which
# REF (a branch or tag) is expected to contain.
checkout_pinned() {
  local dir=$1 repo=$2 ref=$3 commit=$4
  if [[ -d $dir/.git ]]; then
    as_build git -C "$dir" remote set-url origin "$repo"
    as_build git -C "$dir" fetch -q origin "$ref"
  else
    as_build git clone -q --branch "$ref" "$repo" "$dir"
  fi
  if ! ((DRY_RUN)) && ! build_env git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    as_build git -C "$dir" fetch -q origin "$commit"
  fi
  as_build git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit"
  if ! ((DRY_RUN)); then
    local head
    head=$(build_env git -C "$dir" rev-parse HEAD)
    [[ $head == "$commit" ]] || die "$repo: checked out $head, expected the pinned $commit"
    # The pin must be on the branch the L1's validators follow.
    build_env git -C "$dir" merge-base --is-ancestor "$commit" "refs/remotes/origin/$ref" 2>/dev/null ||
      die "$repo: the pinned $commit is not on $ref"
  fi
}

# --- Chains ---------------------------------------------------------------------
# chain_var CHAIN FIELD: the pin, e.g. chain_var btcvm VM_ID.
chain_var() {
  local name="${1}_$2"
  printf '%s' "${!name}"
}

is_known_chain() {
  local c
  for c in $ALL_CHAINS; do [[ $c == "$1" ]] && return 0; done
  return 1
}

# parse_chain_list LIST: prints the chains in LIST (comma or space
# separated; "all" or "none"), in the canonical order, or dies.
parse_chain_list() {
  local list=${1//,/ } c out=() want=' '
  case $list in
    all) printf '%s' "$ALL_CHAINS"; return ;;
    none | '') return ;;
  esac
  for c in $list; do
    c=${c,,}
    case $c in dogecoinvm | dogecoin | doge) c=dogevm ;; btc) c=btcvm ;; ltc) c=ltcvm ;; esac
    is_known_chain "$c" || die "unknown chain '$c': use any of ${ALL_CHAINS// /,}, all or none"
    want+="$c "
  done
  for c in $ALL_CHAINS; do [[ $want == *" $c "* ]] && out+=("$c"); done
  printf '%s' "${out[*]}"
}
