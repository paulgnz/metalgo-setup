# shellcheck shell=bash disable=SC2034
# Every pin metalgo-setup uses, in one place: versions, commits, hashes and
# the IDs of the Metal mainnet L1s. Everything here is public. Secrets never
# go in this file. Sourced by bash: keep it to plain NAME=value lines.
#
# The L1 pins are exactly what the L1's validators run: every node on an L1
# must run the same plugin build, or it stops agreeing with the others. Change
# one only when the L1's validators move to the new commit.

# --- metalgo ------------------------------------------------------------------
# The release tag, and the commit it must resolve to:
#   git ls-remote https://github.com/MetalBlockchain/metalgo 'refs/tags/vX.Y.Z^{}'
METALGO_VERSION=v1.13.5
METALGO_COMMIT=d93bc237d3b4b6f7bb395c8a36b4069a7a222489
METALGO_REPO=https://github.com/MetalBlockchain/metalgo
# The plugin protocol this metalgo speaks (metalgo --version prints
# rpcchainvm=N). The L1 plugins below are built against it; a node on another
# protocol can't load them.
METALGO_RPCCHAINVM=43
# The official linux-amd64 release tarball. MetalBlockchain publishes no
# SHA256SUMS file; this is the SHA-256 GitHub records for the release asset
# (gh release view v1.13.5 -R MetalBlockchain/metalgo --json assets), checked
# by downloading it. setup.sh also checks that the binary inside reports this
# version and rpcchainvm. --build-from-source builds METALGO_COMMIT instead.
METALGO_TARBALL_URL=https://github.com/MetalBlockchain/metalgo/releases/download/${METALGO_VERSION}/metalgo-linux-amd64-${METALGO_VERSION}.tar.gz
METALGO_TARBALL_SHA256=3ace215f1fdc77e862ad6e74ca77c49aeaa896b04a09083c69992d78a25af8d3
METALGO_TARBALL_DIR=metalgo-${METALGO_VERSION}

# --- Go, for building the L1 plugins (and metalgo with --build-from-source) ---
# The SHA-256 of the linux-amd64 tarball, from https://go.dev/dl/.
GO_VERSION=1.24.11
GO_SHA256=bceca00afaac856bc48b4cc33db7cd9eb383c81811379faed3bdbc80edb0af65
GO_URL=https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz

# --- The L1s --------------------------------------------------------------------
# The chains setup.sh knows, by short name (the --chains names).
ALL_CHAINS="btcvm ltcvm dogevm"

# For each chain: its title, its L1 on Metal mainnet (chain, subnet, VM),
# the source of its plugin (repository, branch, commit, Go package), and the
# public read-only JSON-RPC used to compare heights.
#
# To update a chain: take the commit the L1's validators moved to
# (git ls-remote REPO refs/heads/BRANCH), read what changed, put its full SHA
# here, then re-run setup.sh on each node.

btcvm_TITLE=BTCVM
btcvm_CHAIN_ID=BYogm85qvZxwX4PitKLDPzNDbAgo61nw2NSXx5VVXyZZ8yGUK
btcvm_SUBNET_ID=SWJQGgyAvXY1aBczr7WupCGpLmukvP2YdXZJUvqm1td37EcJm
btcvm_VM_ID=kMtihm7W3KssmcJb9mzwZfC6gkiPrJhWaa5KMLHdEB9R8Q4pp
btcvm_REPO=https://github.com/MetalBlockchain/btc-vm
btcvm_BRANCH=feature/l1-validators
btcvm_COMMIT=dabb0a9e797f96d64f24319b426748a4e5ca959c
btcvm_PLUGIN_PKG=./cmd/btcvm-plugin
btcvm_PUBLIC_RPC=https://metalbtc.com/rpc
btcvm_PUBLIC_RPC_AUTH=public:public
btcvm_ADDRESS_RE='^(bc1[02-9ac-hj-np-z]{11,71}|[13][1-9A-HJ-NP-Za-km-z]{25,34})$'
btcvm_L1_TOOL=btcvm-l1

ltcvm_TITLE=LTCVM
ltcvm_CHAIN_ID=oUbDoas3uim368iAQamSWWCWU9sXrq854Mtvv4iFSTUYsEBzm
ltcvm_SUBNET_ID=dhgtUfqjhYGfRkiN5dzF3ETmPHo1nDQvmLL2G7zJAVAXUujH3
ltcvm_VM_ID=pmL3MUsaBCgrTSaEiSy2NL6vXGtUcosT3TyXUL421W9hGa2g5
ltcvm_REPO=https://github.com/MetalBlockchain/ltc-vm
ltcvm_BRANCH=feature/l1-validators
ltcvm_COMMIT=971e042968c4e1739335aa9dbdde57640458c359
ltcvm_PLUGIN_PKG=./cmd/ltcvm-plugin
ltcvm_PUBLIC_RPC=https://metalltc.com/rpc
ltcvm_PUBLIC_RPC_AUTH=public:public
ltcvm_ADDRESS_RE='^(ltc1[02-9ac-hj-np-z]{11,71}|[LM3][1-9A-HJ-NP-Za-km-z]{25,34})$'
ltcvm_L1_TOOL=ltcvm-l1

dogevm_TITLE=DogecoinVM
dogevm_CHAIN_ID=2hFCfzdMmfXBxYgvvdL7BYiJAxdejyn4AksMYUM2eM5gN7Xrjy
dogevm_SUBNET_ID=2t2zEB1T3mNUE2WoheMFMjfhAvQJawtgiwnKPJz2NsFk7FDgyN
dogevm_VM_ID=mEUwHwfd8UTHf23UYkQxHvy1n1EGwWieXQnjmtzSryJRZckzu
dogevm_REPO=https://github.com/MetalBlockchain/dogecoin-vm
dogevm_BRANCH=feature/l1-validators
dogevm_COMMIT=636081f396b0e9266c9431f40537102ce72c7972
dogevm_PLUGIN_PKG=./cmd/dogevm-plugin
dogevm_PUBLIC_RPC=https://metaldoge.com/rpc
dogevm_PUBLIC_RPC_AUTH=public:public
dogevm_ADDRESS_RE='^[DA9][1-9A-HJ-NP-Za-km-z]{25,34}$'
dogevm_L1_TOOL=dogevm-l1

# --- Validator admins -------------------------------------------------------------
# The P-Chain addresses whose approval an L1's validators need before they
# sign a validator change (proof of authority; vm/validator_manager.go in
# each VM repo). Written into every chain config as "validatorAdmins", so a
# node registered as a validator co-signs approved changes. Public
# addresses, space-separated. The COMMIT pins above have the validator
# manager (reviewed; it signs nothing while no admins are set, and block
# validity is unchanged). Empty until the admins' keys exist and the L1's
# own validators run it: until then the L1 takes no new validators.
btcvm_VALIDATOR_ADMINS=""
ltcvm_VALIDATOR_ADMINS=""
dogevm_VALIDATOR_ADMINS=""
# How many of those admins must approve a change ("validatorAdminThreshold").
# Empty: the VM's default, a majority of them. Never 1 with several admins,
# or one stolen admin key could change the validator set.
btcvm_VALIDATOR_ADMIN_THRESHOLD=""
ltcvm_VALIDATOR_ADMIN_THRESHOLD=""
dogevm_VALIDATOR_ADMIN_THRESHOLD=""

# --- Sizing (measured), for the preflight warnings ------------------------------
# metalgo syncing only the P-Chain: ~170-200 MB RAM, ~235 MB database. Each L1
# plugin: ~150-180 MB RAM, under 1 GB of disk today.
PLUGIN_RAM_MB=180
WARN_MEM_AVAILABLE_MB=1024
WARN_DISK_FREE_GB=5
