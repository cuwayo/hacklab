# hacklab

**hacklab** provisions a ready-to-use reverse-engineering / dev VM on Hetzner Cloud
with OpenTofu and cloud-init. One `tofu apply` creates a hardened Ubuntu 26.04 server
with a full C/C++/Rust/Node toolchain, Ghidra, and the `rea` agent, already installed
and configured for your login user. SSH in and start working — no post-install steps.

---

## What you get

| Area | Installed |
|---|---|
| Base | git, curl, wget, build-essential, tmux, vim, htop, jq, unzip, ripgrep (`rg`), fd (`fd`/`fdfind`) |
| C/C++ | gcc, g++, clang, make, cmake, ninja |
| Debug / RE | gdb, strace, ltrace, binutils, radare2, Ghidra 12.1.4 (JDK 21), rea |
| Rust | rustup + stable toolchain |
| Node.js | current LTS via **fnm** |
| Bun | official installer |
| Python | **uv** |
| AI | **Claude Code** (native installer) |
| Hardening | key-only SSH, no root login, passwordless sudo, unattended-upgrades, fail2ban |

---

## Prerequisites

1. **OpenTofu** (`tofu`) — install from https://opentofu.org/docs/intro/install/.
   This project was written and validated against **OpenTofu v1.13.1**.
2. **A Hetzner Cloud account and API token.**
   - Create a project at https://console.hetzner.cloud/.
   - Security → API tokens → generate a token with **Read & Write**.
   - Export it as `HCLOUD_TOKEN` (see Quickstart). It is **never** written to any file.
3. **An SSH key pair.** Defaults to `~/.ssh/id_ed25519.pub`; override with
   `ssh_public_key_path` if you use a different key.

You do **not** need the `hcloud` CLI — OpenTofu talks to the API directly.

---

## Quickstart

```bash
cd hacklab
export HCLOUD_TOKEN="your-hetzner-api-token-here"

make init          # download the hcloud provider (run once)
make plan          # review what will be created
make up            # create the server, then wait until provisioning finishes
make ssh           # open a shell as your user
```

`make up` blocks until cloud-init has finished (it polls for the `/var/lib/hacklab/ready`
marker). The **first boot takes several minutes** — it is downloading Ghidra (~570 MB)
and a JDK, and building the toolchain.

Before you apply for real, copy the example variables and **restrict SSH to your IP**:

```bash
cp terraform.tfvars.example terraform.tfvars
curl -s https://ifconfig.me; echo          # find your IP
# then edit allowed_ssh_cidrs = ["<your-ip>/32"]
```

> ⚠️ **The default `allowed_ssh_cidrs = ["0.0.0.0/0"]` exposes SSH to the entire
> internet.** Change it to your own IP before applying. See [Security](#security-notes).

---

## Troubleshooting

### `SSH key not unique (uniqueness_error, 409)`

```
│ Error: API request failed
│   with hcloud_ssh_key.hacklab,
│ SSH key not unique (uniqueness_error, ...)
│ Status code: 409
```

Hetzner Cloud SSH keys are **global to the project and unique by key material**. If a
key with the same public key already exists in the project (uploaded earlier, from a
previous attempt, or manually), the create is rejected. The fix is to **adopt the
existing key** instead of creating a duplicate:

```bash
export HCLOUD_TOKEN=...
make adopt-ssh-key                    # or: make adopt-ssh-key SSH_PUBKEY=~/.ssh/id_ed25519.pub
make up
```

`make adopt-ssh-key` looks up the project key matching your local public key and
imports it into OpenTofu state (`tofu import hcloud_ssh_key.hacklab <id>`). It only
touches state — no API changes. The following plan may show the key being renamed to
`hacklab-key`, which is harmless.

If you'd rather start clean, delete the stray key in the Hetzner console
(Security → SSH keys) and re-run `make up`.

> **Note:** if a *partial* apply already created the firewall and password, just re-run
> `make up` after adopting the key — the already-created resources are in state and
> will be left as-is.

---

## Checking setup progress

Provisioning logs to the server. To watch it live:

```bash
make logs
# or directly:
ssh user@<server-ip> 'tail -f /var/log/hacklab-setup.log'
```

When it is done, a marker file appears:

```bash
make status        # shows outputs + whether the box is provisioned
```

If you closed the terminal during `make up`, re-run `make wait-ready` to block until
the marker exists. When provisioning is complete, run the verification table:

```bash
make verify        # per-tool versions + Ghidra smoke test
```

---

## Getting the password

A random password is generated for **console / rescue access only** (normal SSH is
key-based). Retrieve it with:

```bash
make password
# or:
tofu output -raw password
```

Use it in the Hetzner web console (VNC) or rescue mode. It is stored in the OpenTofu
state — see [Security](#security-notes).

---

## Ghidra usage

Ghidra is installed to `/opt/ghidra` with `GHIDRA_INSTALL_DIR=/opt/ghidra` set
system-wide, and `analyzeHeadless` / `ghidraRun` symlinked into `/usr/local/bin`.
Headless mode is the intended way to use it on this server.

**Copy a binary to the server:**

```bash
scp ./suspect.bin user@<server-ip>:~/
```

**Analyze it headlessly** (creates a project in `~/ghidra-projects`):

```bash
ssh user@<server-ip>

cd ~/ghidra-projects
analyzeHeadless . myproj -import ~/suspect.bin

# Re-open without re-analyzing, or run a script over the imported program:
analyzeHeadless . myproj -process suspect.bin -noanalysis \
  -postScript /path/to/MyScript.java
```

**Copy results back to your laptop** (export with a Ghidra script, or just pull the
project / any files your script wrote):

```bash
scp -r user@<server-ip>:~/ghidra-projects/myproj .
scp user@<server-ip>:~/ghidra-projects/myproj/decompiled.c .
```

**Optional: the Ghidra GUI over SSH X11 forwarding.**
The minimal X11 libraries are installed, so if you have an X server locally you can run:

```bash
ssh -X user@<server-ip>
ghidraRun
```

This is optional and can be slow over a WAN — headless mode is preferred.

---

## Cost

The default `cpx32` (4 vCPU / 8 GB RAM / 160 GB NVMe) is **€35.49/month** plus a
**€0.50/month** IPv4 (≈ **€36/month**, excl. VAT; ≈ **$42.6/month**). Verified against
Hetzner's pricing on 2026-10-15 — prices and plan names change, so check
https://www.hetzner.com/cloud/ before applying.

Cheaper options that still meet the ≥8 GB / ≥4 vCPU bar:

| Type | vCPU | RAM | Disk | €/mo (excl. IPv4) | Notes |
|---|---|---|---|---|---|
| `cx33` | 4 | 8 GB | 80 GB | 8.49 | **Currently shown "not available"** by Hetzner |
| `cpx32` | 4 | 8 GB | 160 GB | 35.49 | **Default** |
| `cpx42` | 8 | 16 GB | 320 GB | 69.49 | More headroom for large binaries |
| `ccx23` | 4 | 16 GB | 160 GB | 85.99 | Dedicated (not shared) vCPU |

> 💸 **Hetzner bills hourly while the server exists.** Run `make destroy` when you are
> done for the day — you only pay for the hours it is up.

---

## Make targets

| Target | What it does |
|---|---|
| `make init` | Initialise the working dir / download the provider |
| `make plan` | Show the execution plan |
| `make up` | Apply, then wait for the ready marker |
| `make ssh` | Open an SSH session |
| `make status` | Show outputs + provisioning state |
| `make password` | Print the console password (sensitive) |
| `make logs` | Tail `/var/log/hacklab-setup.log` |
| `make wait-ready` | Block until the marker exists |
| `make verify` | Run the on-server verification + Ghidra smoke test |
| `make destroy` | Delete everything (stops billing) |
| `make fmt` / `make validate` | Format / validate the config |

---

## Variables

All have sensible defaults and are overridable via `terraform.tfvars`, `-var`, or the
matching environment variable.

| Variable | Default | Notes |
|---|---|---|
| `image` | `ubuntu-26.04` | Hetzner Rapid Deploy image |
| `server_type` | `cpx32` | 4 vCPU / 8 GB — smallest box suited to Ghidra |
| `location` | `nbg1` | `fsn1` also works (CPX capacity in fsn1 is currently tight) |
| `server_name` | `hacklab` | Also the hostname |
| `username` | `user` | Login user (bash, sudo group, passwordless sudo) |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Key installed for the login user |
| `allowed_ssh_cidrs` | `["0.0.0.0/0"]` | **Restrict this to your IP** |
| `ghidra_version` | `12.1.4` | Bare version or full tag; `latest` resolves at boot |
| `ghidra_sha256` | `""` | Optional pinned checksum (uses GitHub's digest by default) |
| `ghidra_jdk_package` | `openjdk-21-jdk` | Ghidra 12.1.x requires JDK 21 |

---

## Security notes

- **The OpenTofu state contains the generated password** (and the server details).
  Keep `terraform.tfstate*` local, never commit it (`.gitignore` already excludes it),
  and prefer a remote backend with encryption if you store state centrally.
- **Restrict the firewall.** The default allows SSH from `0.0.0.0/0`. Set
  `allowed_ssh_cidrs` to your own IP (`["203.0.113.7/32"]`). Only SSH and ICMP are
  inbound; everything else is outbound-only.
- **The API token is never hardcoded.** It is read from `HCLOUD_TOKEN` only.
- **Analyzing malware here is risky.** This VM is internet-connected and shares your
  Hetzner project. Treat it as disposable: never run untrusted samples with your real
  credentials present, use `make destroy` to wipe it, and consider a dedicated Hetzner
  project so a compromise cannot reach other resources.
- Password auth over SSH is disabled; root login is disabled. The password is only for
  the out-of-band web console.

---

## Ubuntu 26.04 caveats (and how they're handled)

Ubuntu 26.04 "Resolute Raccoon" (released 2026-04-23) differs from 24.04 in ways that
affect provisioning. These were verified against current sources before writing the code:

1. **`sudo-rs` is the default sudo provider.** Passwordless sudo uses a drop-in at
   `/etc/sudoers.d/90-hacklab` with `NOPASSWD:ALL` (supported by sudo-rs). It is
   validated at boot with `visudo -c -f` (using the separate-flag form, since 26.04's
   `visudo-rs` documents `-c` and `-f` individually), and the script then proves
   passwordless sudo actually works with `sudo -n true`.
2. **Rust-based coreutils (uutils) are default**, with a documented carve-out: `cp`,
   `mv`, `rm` are still GNU in 26.04. Nothing in the setup relies on GNU-specific
   behavior of those tools, so no changes were needed.
3. **`fd-find` installs the binary as `fdfind`** (not `fd`). The setup creates a
   `/usr/local/bin/fd` symlink. Likewise **`ripgrep` installs `rg`**.
4. **NodeSource does not support 26.04 yet** (its support matrix stops at 24.04).
   Node.js LTS is therefore installed with **fnm** instead. `node`/`npm` are symlinked
   into `/usr/local/bin` so they work in non-interactive shells too.
5. **Socket-activated SSH.** The hardening drop-in is `00-hacklab.conf` (numbered to
   sort *first* in `sshd_config.d/`, because sshd uses the first value it sees and the
   Include sits at the top of `sshd_config` — this beats cloud-init's own
   `50-cloud-init.conf`). It is validated with `sshd -t` **and** the effective values are
   confirmed with `sshd -T` before any restart; the restart is guarded so a bad config
   can't lock you out.
6. **All other requested packages exist in 26.04** (verified against
   packages.ubuntu.com, suite `resolute`) — none had to be skipped.
7. **Ghidra requires JDK 21**, and `openjdk-21-jdk` is available in 26.04. (Note: the
   Ghidra *master* README says JDK 25 — that is the unreleased dev branch; released
   12.1.x requires **JDK 21**. The setup uses JDK 21 and falls back to a Temurin 21
   tarball if the apt package is ever unavailable.)

### One deliberate deviation from the requested file layout

The spec listed `cloud-init/cloud-init.yaml.tftpl` only. This project adds
**`cloud-init/setup.sh`**, which holds the provisioning shell logic; `main.tf` reads it
with `file()` + `indent()` and embeds it into the template. This keeps shell code out of
the Terraform template string, avoiding `${...}` interpolation-escaping bugs, and makes
the script independently lintable (`bash -n`). The rendered `user_data` is byte-identical
to `setup.sh` (verified).

---

## Adding another tool later

The provisioning script is idempotent and lives in `cloud-init/setup.sh`. To add a tool:

1. **A system package?** Add it to the `apt_install` list in `cloud-init/setup.sh`.
   `apt_install` silently skips packages that don't exist in this Ubuntu release, so a
   missing package won't break the whole setup.
2. **A user-level tool?** Add an install step in the "user tools" section, run it with
   `as_user '...'` (never as root), then add any new binaries to the `link_user_bins`
   function so they land in `/usr/local/bin` and work in non-interactive SSH sessions.
3. **Then** run `make fmt && make validate`, and re-provision. Because cloud-init only
   runs on first boot, either `make destroy && make up`, or re-run the script manually:
   `ssh user@<host> 'sudo /usr/local/sbin/hacklab-setup.sh'`.
4. To have `make verify` check it, add a row to the `CHECKS` array in
   `scripts/verify.sh`.

---

## Repository layout

```
hacklab/
├── README.md
├── LICENSE                  # MIT
├── Makefile
├── .gitignore
├── main.tf                  # server, ssh key, firewall, password
├── variables.tf
├── outputs.tf
├── versions.tf              # pinned OpenTofu + provider versions
├── terraform.tfvars.example
├── cloud-init/
│   ├── cloud-init.yaml.tftpl   # user identity, sudo, sshd, runs setup.sh
│   └── setup.sh                # the provisioning logic (rendered into user_data)
└── scripts/
    ├── wait-ready.sh           # blocks until /var/lib/hacklab/ready exists
    ├── verify.sh               # version table + Ghidra smoke test
    └── adopt-ssh-key.sh        # imports an existing project SSH key
```

---

## License

MIT — see [LICENSE](LICENSE).
