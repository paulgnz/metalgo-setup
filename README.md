<p align="center">
  <img src="docs/img/btcvm.png" width="96" alt="BTCVM">&nbsp;&nbsp;&nbsp;
  <img src="docs/img/ltcvm.png" width="96" alt="LTCVM">&nbsp;&nbsp;&nbsp;
  <img src="docs/img/dogevm.png" width="96" alt="DogecoinVM">
</p>

<h1 align="center">metalgo-setup</h1>

<p align="center">
  Run Bitcoin, Litecoin and Dogecoin on Metal Blockchain, from one command.
</p>

<p align="center">
  <img src="docs/img/metalgo-setup.gif" width="960" alt="sudo ./setup.sh finds your Metal node, builds and verifies the BTCVM, LTCVM and DogecoinVM plugins, and bootstraps all three L1s">
</p>

**BTCVM**, **LTCVM** and **DogecoinVM** are Metal Blockchain L1s that run
Bitcoin's, Litecoin's and Dogecoin's own rules (a payment is final once it's
in a block, typically within a couple of seconds), and hold real BTC, LTC and
DOGE through a two-way peg with each coin's own chain.

metalgo-setup is the easy way to run them:

- **New to Metal?** On a fresh Ubuntu 24.04 server it sets up a Metal node
  for you, locked down and ready to go, and adds the L1s you pick.
- **Already run a Metal node or validator?** It adds the L1s to it and leaves
  everything else as it is: same binary, staking key, NodeID and settings.
  One restart, a few seconds.

```sh
git clone https://github.com/paulgnz/metalgo-setup
cd metalgo-setup
sudo ./setup.sh            # a short menu walks you through it
```

### Why run them

Every node that runs an L1 checks every block for itself and serves the
chain: more copies, more independence, a stronger network.

**Earning:** there is no block reward on these L1s. The validator that builds
each block takes its transaction fees, paid in BTC on BTCVM, LTC on LTCVM
and DOGE on DogecoinVM, all backed by the peg. Today those fees are small
(wallets pay about 1 sat, litoshi or koinu per payment). And the L1s **don't
take outside validators yet**: a node you set up now is a *follower*. It
syncs and serves the chain but builds no blocks, so it earns nothing yet.
It's ready to be registered as a validator when that opens. (Validating the
Metal primary network, which earns METAL staking rewards, is separate: see
`--mode full`.)

Developed by Paul Grey @ [metallicus.com](https://metallicus.com).

## What happens

- On a **fresh server** it installs a Metal node: the pinned metalgo, running
  as its own user under a hardened systemd unit, with a firewall and
  automatic security updates. Then it adds whichever L1s you choose.
- On a server that **already runs metalgo**, including a primary-network
  validator, it adds the L1s and changes nothing else about the node: same
  binary, staking key, NodeID and settings, apart from the list of subnets it
  tracks.

## Requirements

Ubuntu 24.04, x86_64 (a fresh install checks this). Measured today:
metalgo syncing only the P-Chain uses about 170–200 MB of RAM with a
~235 MB database, and each L1 plugin about 150–180 MB of RAM and under 1 GB
of disk. (On six 4 GB servers validating all three L1s: metalgo ~200 MB,
the three plugins ~490 MB, ~2.8 GB free. A new node's first P-Chain sync
briefly takes about 2 GB, until its first restart.)

| Node | CPU | RAM | Disk |
|---|---|---|---|
| **l1-only** node with all three L1s (P-Chain only) | 2 vCPU | 4 GB | 40 GB SSD |
| Adding the three L1s to an existing node (e.g. 16 GB) | — | about +0.6 GB | a few GB |
| **full** primary-network node ([metalgo's minimum](https://github.com/MetalBlockchain/metalgo#installation)) | 8 vCPU | 16 GiB | 250 GiB SSD, and growing |

A full node also needs a reliable network connection with its staking port
(9651) open to the internet. setup.sh warns if less than 1 GB of memory is
available or less than 5 GB of disk is free.

## What it does

**Fresh server** (no metalgo service found):

- metalgo **v1.13.5** (commit `d93bc237`), from the official release
  tarball, checked against its pinned SHA-256; the binary must report
  v1.13.5, that commit and plugin protocol `rpcchainvm=43`.
  `--build-from-source` builds the pinned commit with the pinned Go instead.
- A `metalgo` system user (no login shell); data in `/var/lib/metalgo`,
  binaries (root-owned) in `/opt/metalgo`, settings in
  `/etc/metalgo/config.json`.
- `metalgo.service`: `KillMode=mixed` and `TimeoutStopSec=120` (metalgo
  stops each L1 plugin cleanly), `NoNewPrivileges`, `ProtectSystem=strict`
  with only the data dir writable, no capabilities, a system-call filter.
- Mode **l1-only** (default): `partial-sync-primary-network`, the P-Chain
  only: the light way to follow the L1s. Mode **full**: the whole primary
  network: the kind of node that can validate Metal and earn staking rewards
  (staking itself is done separately, with your METAL).
- Firewall (ufw): SSH and the staking port 9651 in, everything else closed.
  The HTTP API listens on 127.0.0.1 only.
- Unattended security updates. With `--harden-ssh`, key-only SSH logins
  (skipped if no SSH key is set up, so you can't be locked out).
- It prints the NodeID and where the staking key and certificate are
  (`/var/lib/metalgo/staking/`). **Back those files up offline**: they are
  the node's identity. setup.sh never reads, prints or copies them.

**Existing metalgo** (found automatically, or `--unit NAME`): it reads the
service's unit and drop-ins (`systemctl cat`), its user, flags, environment
and `--config-file`, and works out the data dir, plugin dir, chain config
dir and tracked subnets the way metalgo v1.13.5 does (a flag beats an
`AVAGO_*` environment variable, which beats the config file, which beats
the default: data dir `$HOME/.metalgo`, and `plugins`, `configs/chains`
under it). It refuses to go on unless the node is on **mainnet** and
`metalgo --version` says **`rpcchainvm=43`**. It doesn't reinstall or
reconfigure metalgo, or touch the firewall or SSH.

**Adding an L1** (any of them, on either kind of node):

1. Builds the plugin from source at its pinned commit, as an unprivileged
   build user (`metalgo-build`), with Go 1.24.11 (SHA-256 pinned, kept in
   `/opt/metalgo-setup`, never `/usr/local/go`).
2. Checks that `go run ./scripts/vm-id-generator.go` prints the L1's VM ID.
3. Puts the plugin in the plugin dir under that VM ID, atomically (a
   rename), and only if it differs from what's there.
4. Writes `<chain-config-dir>/<chain ID>/config.json`, only if the chain has
   no config yet: the L1's own database and logs under the node's data dir
   (`<data-dir>/l1/<chain>/`); with `--rpc`, a local JSON-RPC with a random
   user and password (file mode 0600) and `txIndex`/`addrIndex`.
5. Adds the L1's subnet to `track-subnets`, keeping every subnet already
   there, in whichever place metalgo reads it from (the unit's flag, or the
   JSON config file; a drop-in for a packaged unit). It reads the result back
   the way metalgo will, and stops if it's not right.
6. If the service lacks `KillMode=mixed`, adds a drop-in with it, so a stop
   can't kill a plugin before metalgo closes it.
7. Restarts metalgo once (it loads plugins and subnets only at start), waits
   for each L1 to bootstrap, and prints its height next to the public RPC's.

Every file it changes is backed up first, under
`/var/backups/metalgo-setup/<time>/` (with its full path).

These L1 nodes are **followers** for now: the L1s have no validator manager
yet, so a node syncs and checks every block and serves the chain, but
doesn't validate it. It is ready to be registered as a validator of each L1
later. **No peg keys, and no Bitcoin, Litecoin or Dogecoin node, are
needed**: those are only for the bridges' signers (see
[bridge-operator](https://github.com/paulgnz/bridge-operator)).

### The L1s

| | BTCVM | LTCVM | DogecoinVM |
|---|---|---|---|
| `--chains` name | `btcvm` | `ltcvm` | `dogevm` |
| Chain ID | `BYogm85qvZxwX4PitKLDPzNDbAgo61nw2NSXx5VVXyZZ8yGUK` | `oUbDoas3uim368iAQamSWWCWU9sXrq854Mtvv4iFSTUYsEBzm` | `2hFCfzdMmfXBxYgvvdL7BYiJAxdejyn4AksMYUM2eM5gN7Xrjy` |
| Subnet ID | `SWJQGgyAvXY1aBczr7WupCGpLmukvP2YdXZJUvqm1td37EcJm` | `dhgtUfqjhYGfRkiN5dzF3ETmPHo1nDQvmLL2G7zJAVAXUujH3` | `2t2zEB1T3mNUE2WoheMFMjfhAvQJawtgiwnKPJz2NsFk7FDgyN` |
| VM ID | `kMtihm7W3KssmcJb9mzwZfC6gkiPrJhWaa5KMLHdEB9R8Q4pp` | `pmL3MUsaBCgrTSaEiSy2NL6vXGtUcosT3TyXUL421W9hGa2g5` | `mEUwHwfd8UTHf23UYkQxHvy1n1EGwWieXQnjmtzSryJRZckzu` |
| Source | [btc-vm](https://github.com/MetalBlockchain/btc-vm) `main` | [ltc-vm](https://github.com/MetalBlockchain/ltc-vm) `main` | [dogecoin-vm](https://github.com/MetalBlockchain/dogecoin-vm) `dogecoin` |
| Public RPC | https://metalbtc.com/rpc | https://metalltc.com/rpc | https://metaldoge.com/rpc |

Every version, commit, hash and ID is in one file, [`lib/pins.sh`](lib/pins.sh).
The L1 commits are exactly what the L1's validators run: every node of an
L1 must run the same plugin, or it stops agreeing with the others.

## Install

### A new node

```sh
sudo ./setup.sh --chains all --dry-run     # see every step first
sudo ./setup.sh --chains all               # l1-only node with the three L1s
sudo ./setup.sh --mode full --chains all   # or: a full primary-network node
```

Then back up `/var/lib/metalgo/staking/` offline.

### Adding the L1s to a node you already run

```sh
sudo ./setup.sh --chains btcvm,dogevm --dry-run
sudo ./setup.sh --chains btcvm,dogevm
```

The dry run shows what setup.sh found (unit, user, directories, tracked
subnets, whether the node validates) and every change it would make. If your
node **validates the Metal primary network**: adding the L1s keeps the same
staking key, NodeID and settings apart from `track-subnets`. The one restart
takes the node offline for a few seconds; uptime counts over the whole
staking period, so it doesn't put rewards at risk. To choose the moment,
use `--no-restart` and later `sudo systemctl restart <unit>`.

### Options

```
--mode full|l1-only   fresh install: the whole primary network, or the P-Chain only (default)
--chains LIST         L1s to add: btcvm,ltcvm,dogevm, all, or none
--rpc                 a local JSON-RPC for each new L1 (random password, mode 0600)
--remove LIST         L1s to remove (data kept unless --purge)
--purge               with --remove: delete their data and configs too
--update              rebuild the L1s on this node at the current pins
--allow-downgrade     install an L1 plugin older than the one installed here
--unit NAME           the existing metalgo service (default: found)
--no-restart          change files, but leave the restart to you
--wait SECONDS        how long to wait for bootstrapping (default 900; 0: don't)
--harden-ssh          fresh install: key-only SSH logins
--public-ip IP        fresh install: this server's public IPv4 (default: detected)
--build-from-source   fresh install: build metalgo instead of using the release
--config FILE         options from FILE (default /etc/metalgo-setup.conf)
--status              show the node and its L1s; change nothing
--dry-run             print every action, do none
-y, --yes             don't ask before restarting
```

The same options can live in `/etc/metalgo-setup.conf`, one `name = value`
per line (see [`metalgo-setup.conf.example`](metalgo-setup.conf.example));
options on the command line win. With neither options nor that file,
`sudo ./setup.sh` asks a few questions instead.

## Verify

```sh
sudo ./setup.sh --status
```

shows the node, its NodeID and role, and for each L1: plugin, pinned
commit, tracked, chain config, bootstrapped, and its height next to the
public RPC's. By hand:

```sh
# Has the L1 bootstrapped? (use your node's API port; 9650 by default)
curl -s -X POST -H 'content-type: application/json' 127.0.0.1:9650/ext/info \
  -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"BYogm85qvZxwX4PitKLDPzNDbAgo61nw2NSXx5VVXyZZ8yGUK"}}'
# The public height, to compare with
curl -s -u public:public -H 'content-type: application/json' https://metalbtc.com/rpc \
  -d '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}'
# metalgo's logs (each L1 logs to <data-dir>/l1/<chain>/logs)
journalctl -u metalgo -f
```

## Validating an L1 and earning its fees

A node set up here follows the L1s; it doesn't validate them until the
L1's admin approves it. Validators take turns building blocks, and each
block pays its transaction fees to the validator that built it. There is
no block reward, and fees are small (about 1 sat, litoshi or koinu per
payment), so for now validating is about securing the chain more than
income.

**How a node becomes a validator** (proof of authority: the admin approves
each one). Each L1's manager is the chain itself. The P-Chain adds a
validator only with a registration the L1's current validators sign, and
they sign only one the admin approved:

1. **Run a node with the L1** (this installer) and let it sync:
   `sudo ./setup.sh --status` shows your NodeID.
2. **Request.** With the L1's tool (`cmd/btcvm-l1`, `cmd/ltcvm-l1`,
   `cmd/dogevm-l1` in its repo), make a request. It's all public: your
   NodeID, BLS key and proof of possession, and the P-Chain address that
   will own the validator's METAL balance. Send it to the admin.
   ```sh
   btcvm-l1 request -node-uri http://127.0.0.1:9650 -owner P-metal1... > request.json
   ```
3. **Approval.** The admin checks who you are, then approves; the
   validators co-sign; the admin sends back `registration.json`, valid for an
   hour.
4. **Register** it on the P-Chain yourself, prepaying the validator's
   continuous P-Chain fee (about 1.3 METAL a month) from your own P-Chain key:
   ```sh
   btcvm-l1 register -registration registration.json -key my-p-chain-key.json -balance 5
   ```
5. **Get paid.** Tell your node where its block fees go (an ordinary BTCVM,
   LTCVM or Dogecoin address; any wallet for that chain can hold it), then
   check:
   ```sh
   sudo ./setup.sh --mining-address btcvm=bc1q...
   sudo ./setup.sh --status        # validator: yes, weight, METAL left, fee address
   ```
6. **Keep it funded.** When the METAL balance runs out, the P-Chain
   deactivates the validator. Anyone can top it up:
   `btcvm-l1 top-up -validation-id ... -key my-p-chain-key.json -balance 5`.

Nothing here needs a special wallet: fees arrive at a normal address, and
the METAL balance is paid with an ordinary P-Chain key.

## Update

```sh
cd metalgo-setup && git pull          # new pins arrive in lib/pins.sh
sudo ./setup.sh --update --dry-run
sudo ./setup.sh --update
```

`--update` rebuilds each L1 on the node at its current pin, installs it only
if it changed, and restarts once. On a node metalgo-setup installed, it also
moves metalgo to the pinned version. It never upgrades a metalgo it didn't
install.

## Remove

```sh
sudo ./setup.sh --remove dogevm            # untrack it, remove the plugin; keep data and config
sudo ./setup.sh --remove dogevm --purge    # and delete its data and chain config
```

It won't remove an L1 this node validates (`--force` overrides that).

## What it doesn't do

- It doesn't stake, register a validator, or handle any key or wallet. It
  never makes, reads, prints or copies a private key.
- It doesn't set up a bridge signer, peg keys, or a Bitcoin, Litecoin or
  Dogecoin node ([bridge-operator](https://github.com/paulgnz/bridge-operator)
  does that).
- On an existing node, it doesn't upgrade or reconfigure metalgo, or change
  the firewall or SSH. It doesn't edit a YAML/TOML config file or
  `AVAGO_TRACK_SUBNETS`: it tells you the exact line to set instead.
- It doesn't overwrite an L1's existing chain config.
- It supports Metal **mainnet** only.

## Development

```sh
make hooks         # pre-commit and pre-push hooks that refuse secrets
make lint          # shellcheck, and the secret scanner's tests
make test          # lint + every scenario in ubuntu:24.04 containers (docker)
make verify-pins   # check lib/pins.sh against upstream (tags, hashes, VM IDs)
```

The container tests ([`test/`](test)) use fake `systemctl`, `ufw` and
`metalgo` and a test mode that downloads and builds nothing. They cover:
fresh installs in both modes, a flags-only unit (like a typical existing
node), a config-file unit, a unit that relies on metalgo's defaults (a
packaged unit, overridden with a drop-in), tracked subnets being preserved,
idempotent re-runs, `--remove` and `--purge`, the refusals (rpcchainvm
mismatch, not mainnet, two services, environment-set subnets, bad options),
and that no password ever reaches the output. `bash -n` runs with Ubuntu
24.04's bash.

## License

BSD 3-Clause; see [LICENSE](LICENSE).
