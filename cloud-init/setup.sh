#!/usr/bin/env bash
#
# hacklab first-boot provisioning. Runs as root, invoked by cloud-init.
#
# Inputs (environment variables, supplied by cloud-init):
#   HACKLAB_USER            login user to provision for            (default: user)
#   HACKLAB_GHIDRA_VERSION  Ghidra release tag, or "latest"        (default: latest)
#   HACKLAB_JDK_PKG         apt package for the JDK                (default: openjdk-21-jdk)
#   HACKLAB_GHIDRA_SHA256   expected sha256 of the Ghidra zip      (default: empty)
#
# Everything is logged to stdout, which cloud-init redirects to
# /var/log/hacklab-setup.log. On success a marker is written to
# /var/lib/hacklab/ready.

set -uo pipefail

USER_NAME="${HACKLAB_USER:-user}"
GHIDRA_VERSION="${HACKLAB_GHIDRA_VERSION:-latest}"
JDK_PKG="${HACKLAB_JDK_PKG:-openjdk-21-jdk}"
GHIDRA_SHA256="${HACKLAB_GHIDRA_SHA256:-}"

USER_HOME="/home/${USER_NAME}"
GHIDRA_DIR="/opt/ghidra"
MARKER="/var/lib/hacklab/ready"
LOG="/var/log/hacklab-setup.log"

# Track whether anything *required* failed. Optional tools never set this.
FAILED=0

log()  { printf '[hacklab] %s %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; FAILED=1; }

# Run a command as the login user with a proper login environment.
as_user() { runuser -l "$USER_NAME" -c "$1"; }

mkdir -p /var/lib/hacklab
touch "$LOG"
# Send our own output to the log too (harmless if cloud-init already redirects).
exec >>"$LOG" 2>&1

log "=== hacklab provisioning start (user=${USER_NAME}, ghidra=${GHIDRA_VERSION}) ==="
log "OS: $(. /etc/os-release && echo "${PRETTY_NAME}")"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------

# Install packages, silently skipping any that don't exist in this Ubuntu release
# (26.04 package names differ from 24.04). Returns non-zero only if a package that
# *does* exist fails to install.
apt_install() {
  local pkgs=() p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    else
      warn "package not in repos, skipping: $p"
    fi
  done
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# ---------------------------------------------------------------------------------
# 1. PATH for the login user (needed before user-level installers run)
# ---------------------------------------------------------------------------------
PATH_BLOCK='# >>> hacklab PATH >>>
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"
export GHIDRA_INSTALL_DIR=/opt/ghidra
# <<< hacklab PATH <<<'

for rc in "${USER_HOME}/.bashrc" "${USER_HOME}/.profile"; do
  if ! grep -q '>>> hacklab PATH >>>' "$rc" 2>/dev/null; then
    printf '\n%s\n' "$PATH_BLOCK" >> "$rc"
  fi
done
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.bashrc" "${USER_HOME}/.profile" 2>/dev/null || true

# System-wide PATH + GHIDRA_INSTALL_DIR for all shells (login, interactive, and
# `ssh host cmd`). User binaries are also symlinked into /usr/local/bin later.
cat > /etc/profile.d/99-hacklab.sh <<'PROFILE'
# hacklab: toolchain paths
export GHIDRA_INSTALL_DIR=/opt/ghidra
PROFILE
chmod 0644 /etc/profile.d/99-hacklab.sh

# ---------------------------------------------------------------------------------
# 2. System packages
# ---------------------------------------------------------------------------------
log "apt-get update"
apt-get update -y || err "apt-get update failed"

log "installing base + RE packages"
apt_install \
  git curl wget ca-certificates gnupg lsb-release \
  build-essential tmux vim htop jq unzip zip tree less bash-completion \
  gcc g++ clang make cmake ninja-build pkg-config \
  gdb strace ltrace binutils file \
  ripgrep fd-find \
  python3 python3-venv \
  unattended-upgrades fail2ban \
  || err "one or more base packages failed to install"

# `fd-find` ships the binary as `fdfind`; expose it as `fd` too.
if [ -x /usr/bin/fdfind ] && [ ! -e /usr/local/bin/fd ]; then
  ln -sf /usr/bin/fdfind /usr/local/bin/fd
fi

# radare2 is optional and often missing from a new Ubuntu release.
apt_install radare2 || warn "radare2 not available — skipping (see README)"

# Minimal X11 libraries so the Ghidra GUI works over `ssh -X` (optional).
apt_install libx11-6 libxext6 libxi6 libxrender1 libxtst6 libfreetype6 \
  fontconfig libgl1 libxrandr2 xauth || warn "some X11 libraries unavailable"

# ---------------------------------------------------------------------------------
# 3. JDK (Ghidra 12.x requires JDK 21+)
# ---------------------------------------------------------------------------------
log "installing JDK (${JDK_PKG})"
if apt-cache show "$JDK_PKG" >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends "$JDK_PKG" || err "JDK install failed"
  log "JDK installed via apt: ${JDK_PKG}"
else
  warn "${JDK_PKG} not in repos; falling back to Temurin 21 tarball"
  if curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" -o /tmp/jdk.tar.gz; then
    mkdir -p /opt/jdk
    tar -xzf /tmp/jdk.tar.gz -C /opt/jdk --strip-components=1 && rm -f /tmp/jdk.tar.gz
    cat > /etc/profile.d/99-java.sh <<'JAVA'
export JAVA_HOME=/opt/jdk
export PATH="/opt/jdk/bin:$PATH"
JAVA
    for b in java javac jar; do [ -x "/opt/jdk/bin/$b" ] && ln -sf "/opt/jdk/bin/$b" "/usr/local/bin/$b"; done
    log "Temurin 21 installed to /opt/jdk"
  else
    err "could not install any JDK"
  fi
fi

# ---------------------------------------------------------------------------------
# 4. Ghidra
# ---------------------------------------------------------------------------------
install_ghidra() {
  local api="https://api.github.com/repos/NationalSecurityAgency/ghidra/releases"
  local ver="$GHIDRA_VERSION" tag rel url digest
  local pin="$GHIDRA_SHA256"

  # Resolve the release tag. Accept "latest", a bare version ("12.1.4"), or the
  # full tag ("Ghidra_12.1.4_build").
  if [ "$ver" = "latest" ] || [ -z "$ver" ]; then
    tag="$(curl -fsSL "$api/latest" | grep -o '"tag_name": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ -n "$tag" ] || { err "could not resolve latest Ghidra tag"; return 1; }
  elif printf '%s' "$ver" | grep -q '^Ghidra_'; then
    tag="$ver"
  else
    tag="Ghidra_${ver}_build"
  fi
  log "Ghidra release tag: ${tag}"

  rel="$(curl -fsSL "$api/tags/${tag}")" || { err "cannot fetch Ghidra release ${tag}"; return 1; }
  url="$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"$/\1/' | grep '_PUBLIC_.*\.zip$' | head -n1)"
  [ -n "$url" ] || { err "no PUBLIC zip asset found for Ghidra ${tag}"; return 1; }
  log "downloading ${url}"

  # GitHub publishes a server-computed sha256 digest per asset; use it unless the
  # caller pinned one via HACKLAB_GHIDRA_SHA256.
  if [ -z "$pin" ]; then
    digest="$(printf '%s' "$rel" | grep -o '"digest": *"sha256:[^"]*"' | head -n1 | sed 's/.*sha256:\([0-9a-f]*\)"$/\1/')"
    pin="$digest"
  fi

  curl -fsSL "$url" -o /tmp/ghidra.zip || { err "Ghidra download failed"; return 1; }

  if [ -n "$pin" ]; then
    if ! printf '%s  %s\n' "$pin" /tmp/ghidra.zip | sha256sum -c -; then
      err "Ghidra checksum mismatch (expected ${pin})"; return 1
    fi
    log "checksum verified (sha256 ${pin})"
  else
    warn "no checksum available from GitHub for this asset; recording computed sha256"
    sha256sum /tmp/ghidra.zip | tee /var/lib/hacklab/ghidra.zip.sha256
  fi

  rm -rf /tmp/ghidra-extract && mkdir -p /tmp/ghidra-extract
  unzip -q /tmp/ghidra.zip -d /tmp/ghidra-extract || { err "unzip failed"; return 1; }
  local d
  d="$(find /tmp/ghidra-extract -maxdepth 1 -type d -name 'ghidra_*' | head -n1)"
  [ -n "$d" ] || { err "unexpected Ghidra zip layout"; return 1; }

  rm -rf "$GHIDRA_DIR"
  mv "$d" "$GHIDRA_DIR"
  chmod +x "$GHIDRA_DIR/ghidraRun" "$GHIDRA_DIR/support/analyzeHeadless" 2>/dev/null || true

  # Expose the entry points to all users.
  ln -sf "$GHIDRA_DIR/support/analyzeHeadless" /usr/local/bin/analyzeHeadless
  ln -sf "$GHIDRA_DIR/ghidraRun" /usr/local/bin/ghidraRun

  log "Ghidra installed to ${GHIDRA_DIR}"
}

if [ ! -x "$GHIDRA_DIR/support/analyzeHeadless" ]; then
  install_ghidra || err "Ghidra installation failed"
else
  log "Ghidra already present, skipping download"
fi

# ---------------------------------------------------------------------------------
# 5. User-level tools (installed as the login user, never root)
# ---------------------------------------------------------------------------------
log "installing user tools for ${USER_NAME}"

# Rust (rustup, stable)
if [ ! -x "${USER_HOME}/.cargo/bin/rustup" ]; then
  as_user 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable' \
    || warn "rustup install failed"
else
  log "rustup already present"
fi

# Node.js LTS via fnm (NodeSource does not support Ubuntu 26.04 yet)
FNM="${USER_HOME}/.local/share/fnm/fnm"
if [ ! -x "$FNM" ]; then
  as_user 'curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell' || warn "fnm install failed"
fi
if [ -x "$FNM" ]; then
  as_user "$FNM install --lts"        || warn "fnm: node LTS install failed"
  as_user "$FNM default lts-latest"   || warn "fnm: could not set default node"
fi

# Bun
if [ ! -x "${USER_HOME}/.bun/bin/bun" ]; then
  as_user 'curl -fsSL https://bun.sh/install | bash' || warn "bun install failed"
fi

# uv (Python)
if [ ! -x "${USER_HOME}/.local/bin/uv" ]; then
  as_user 'curl -LsSf https://astral.sh/uv/install.sh | sh' || warn "uv install failed"
fi

# Claude Code (native installer; must not run as root)
if [ ! -x "${USER_HOME}/.local/bin/claude" ]; then
  as_user 'curl -fsSL https://claude.ai/install.sh | bash' || warn "Claude Code install failed"
fi

# ---------------------------------------------------------------------------------
# 6. Make user binaries reachable from every kind of shell (including `ssh host cmd`)
# ---------------------------------------------------------------------------------
link_user_bins() {
  local b nb
  for b in rustup cargo rustc rustfmt cargo-clippy clippy-driver; do
    [ -x "${USER_HOME}/.cargo/bin/${b}" ] && ln -sf "${USER_HOME}/.cargo/bin/${b}" "/usr/local/bin/${b}"
  done
  for b in uv uvx claude; do
    [ -x "${USER_HOME}/.local/bin/${b}" ] && ln -sf "${USER_HOME}/.local/bin/${b}" "/usr/local/bin/${b}"
  done
  [ -x "${USER_HOME}/.bun/bin/bun" ] && ln -sf "${USER_HOME}/.bun/bin/bun" /usr/local/bin/bun

  nb="$(ls -d "${USER_HOME}"/.local/share/fnm/node-versions/*/installation/bin 2>/dev/null | head -n1)"
  if [ -n "$nb" ]; then
    for b in node npm npx corepack; do
      [ -x "${nb}/${b}" ] && ln -sf "${nb}/${b}" "/usr/local/bin/${b}"
    done
  fi
}
link_user_bins
log "linked user binaries into /usr/local/bin"

# ---------------------------------------------------------------------------------
# 7. rea (https://github.com/morluto/rea) — clone + install the CLI
# ---------------------------------------------------------------------------------
REA_DIR="${USER_HOME}/tools/rea"
if [ ! -d "${REA_DIR}/.git" ]; then
  as_user "mkdir -p '${USER_HOME}/tools' && git clone https://github.com/morluto/rea.git '${REA_DIR}'" \
    || warn "rea clone failed"
else
  log "rea already cloned"
fi

# The published CLI is the supported way to use rea (npm package: rea-agents).
if ! command -v rea >/dev/null 2>&1; then
  as_user 'npm install --global rea-agents' || warn "rea CLI (npm) install failed"
fi
# Re-link now that rea may exist in the node bin dir.
link_user_bins

# Register rea with detected agents (non-interactive). Tolerate failure.
if command -v rea >/dev/null 2>&1; then
  as_user 'rea setup --yes --all-detected --json' >/dev/null 2>&1 || warn "rea setup did not complete (run 'rea setup' manually)"
fi

# ---------------------------------------------------------------------------------
# 8. Ghidra project directory + ownership
# ---------------------------------------------------------------------------------
install -d -o "$USER_NAME" -g "$USER_NAME" "${USER_HOME}/ghidra-projects"
install -d -o "$USER_NAME" -g "$USER_NAME" "${USER_HOME}/tools"

# ---------------------------------------------------------------------------------
# 9. SSH hardening — validate before restarting (26.04 uses socket-activated sshd)
# ---------------------------------------------------------------------------------
log "validating sshd configuration"
if sshd -t; then
  log "sshd config syntax OK"
  # Syntax is not enough: confirm the EFFECTIVE values are the hardened ones.
  # (sshd_config.d/ is included from the top of sshd_config, so 00-hacklab.conf
  # must win over cloud-init's 50-cloud-init.conf.)
  eff="$(sshd -T 2>/dev/null || true)"
  if printf '%s\n' "$eff" | grep -qi '^passwordauthentication no' \
     && printf '%s\n' "$eff" | grep -qi '^permitrootlogin no' \
     && printf '%s\n' "$eff" | grep -qi '^pubkeyauthentication yes'; then
    log "effective sshd settings hardened (passwordauth=no, permitrootlogin=no)"
  else
    warn "effective sshd settings are NOT fully hardened — check sshd -T:"
    printf '%s\n' "$eff" | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication)' | while read -r l; do warn "  $l"; done
    # Still restart: key login keeps working even if password auth remained on.
  fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  systemctl restart ssh.socket 2>/dev/null || true
else
  err "sshd configuration is invalid — not restarting"
fi

# ---------------------------------------------------------------------------------
# 10. Passwordless sudo — validate with the installed sudo implementation
# ---------------------------------------------------------------------------------
log "validating sudoers drop-in"
SUDOERS="/etc/sudoers.d/90-hacklab"
# Ubuntu 26.04 ships sudo-rs; its visudo-rs documents -c and -f as separate flags,
# so avoid the combined -cf form.
if command -v visudo >/dev/null 2>&1; then
  visudo -c -f "$SUDOERS" || err "sudoers validation failed (${SUDOERS})"
else
  warn "no visudo found; skipping syntax check"
fi
if runuser -l "$USER_NAME" -c 'sudo -n true' 2>/dev/null; then
  log "passwordless sudo verified"
else
  err "passwordless sudo is NOT working for ${USER_NAME}"
fi

# ---------------------------------------------------------------------------------
# 11. unattended-upgrades + fail2ban
# ---------------------------------------------------------------------------------
systemctl enable --now unattended-upgrades 2>/dev/null || warn "could not enable unattended-upgrades"
systemctl enable --now fail2ban 2>/dev/null || warn "could not enable fail2ban"

# ---------------------------------------------------------------------------------
# 12. Done
# ---------------------------------------------------------------------------------
log "=== hacklab provisioning finished (failed=${FAILED}) ==="
if [ "$FAILED" -eq 0 ]; then
  date -u +%FT%TZ > "$MARKER"
  log "ready marker written: ${MARKER}"
else
  err "provisioning finished with errors; ready marker NOT written"
fi
exit "$FAILED"
