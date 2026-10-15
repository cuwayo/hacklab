#!/usr/bin/env bash
#
# verify.sh — run ON the hacklab server to prove the toolchain is present.
#
# Prints a table of each tool and its version, plus the OS version and which
# sudo implementation is installed, then does a Ghidra smoke test (headless
# import of a tiny compiled binary). Exits non-zero if anything is missing.
#
# Usage (normally invoked via `make verify` from your laptop):
#   ssh user@<host> 'bash -s' < scripts/verify.sh
# or copy it over and run it:
#   scp scripts/verify.sh user@<host>:/tmp/ && ssh user@<host> bash /tmp/verify.sh

set -uo pipefail

FAIL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# Tools are installed for the login user; make sure we see the same PATH a login
# shell would (rustup/cargo, fnm node, ~/.bun/bin, ~/.local/bin for uv/claude).
export PATH="${HOME}/.cargo/bin:${HOME}/.bun/bin:${HOME}/.local/bin:${HOME}/.local/share/fnm:${PATH}"
if [ -s "${HOME}/.local/share/fnm/fnm" ]; then
  eval "$("${HOME}/.local/share/fnm/fnm" env --shell bash 2>/dev/null)" || true
fi

# ---------------------------------------------------------------------------------
# Version table
# ---------------------------------------------------------------------------------
# Format: "label|command"  (command is eval'd; first line of output is shown)
CHECKS=(
  "gcc|gcc --version"
  "g++|g++ --version"
  "clang|clang --version"
  "make|make --version"
  "cmake|cmake --version"
  "ninja|ninja --version"
  "gdb|gdb --version"
  "strace|strace --version"
  "ltrace|ltrace --version 2>&1 | head -n1"
  "binutils|ld --version"
  "git|git --version"
  "ripgrep|rg --version"
  "fd|fd --version || fdfind --version"
  "jq|jq --version"
  "python (uv)|uv --version"
  "node|node --version"
  "npm|npm --version"
  "bun|bun --version"
  "rustc|rustc --version"
  "cargo|cargo --version"
  "claude|claude --version"
  "java|java -version 2>&1 | head -n1"
  "ghidra|cat \"${GHIDRA_INSTALL_DIR:-/opt/ghidra}\"/Ghidra/application.properties 2>/dev/null | grep -i '^application.version' || echo 'analyzeHeadless present'"
  "rea|rea --version 2>&1 | head -n1"
)

printf '\n%-16s %-12s %s\n' "TOOL" "STATUS" "VERSION"
printf '%-16s %-12s %s\n' "----------------" "------------" "----------------------------------------"

for entry in "${CHECKS[@]}"; do
  label="${entry%%|*}"
  cmd="${entry#*|}"
  if out="$(eval "${cmd}" 2>&1)" && [ -n "${out}" ]; then
    printf '%-16s %-12s %s\n' "${label}" "ok" "$(printf '%s' "${out}" | head -n1)"
  else
    printf '%-16s %-12s %s\n' "${label}" "MISSING" "${out:-not found}"
    FAIL=1
  fi
done

# radare2 is optional (may not be packaged for this Ubuntu release) — report only.
printf '\n'
if command -v r2 >/dev/null 2>&1; then
  printf '%-16s %-12s %s\n' "radare2" "ok" "$(r2 -v 2>&1 | head -n1)"
else
  printf '%-16s %-12s %s\n' "radare2" "optional" "not installed (see README caveats)"
fi

# ---------------------------------------------------------------------------------
# OS + sudo implementation
# ---------------------------------------------------------------------------------
printf '\n== OS ==\n'
if command -v lsb_release >/dev/null 2>&1; then
  lsb_release -a 2>/dev/null
else
  cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='
fi

printf '\n== sudo ==\n'
if command -v sudo >/dev/null 2>&1; then
  echo "binary: $(command -v sudo)"
  # sudo-rs prints a distinct version banner.
  sudo --version 2>&1 | head -n2
  if sudo --version 2>&1 | grep -qi 'sudo-rs\|rs-sudo'; then
    echo "implementation: sudo-rs (Rust)"
  else
    echo "implementation: classic sudo (GNU/C)"
  fi
  # Passwordless sudo must actually work.
  if sudo -n true 2>/dev/null; then
    echo "passwordless sudo: ok"
  else
    echo "passwordless sudo: FAILED (NOPASSWD not effective)"
    FAIL=1
  fi
  # Validate the drop-in syntax with whatever validator this sudo ships.
  if sudo -l >/dev/null 2>&1 || sudo -n -l >/dev/null 2>&1; then
    echo "sudoers parse: ok"
  else
    echo "sudoers parse: FAILED"
    FAIL=1
  fi
else
  echo "sudo: MISSING"
  FAIL=1
fi

# ---------------------------------------------------------------------------------
# Ghidra smoke test
# ---------------------------------------------------------------------------------
printf '\n== Ghidra headless smoke test ==\n'
if ! command -v analyzeHeadless >/dev/null 2>&1; then
  echo "analyzeHeadless not on PATH — skipping smoke test"
  FAIL=1
else
  SRC="${TMPDIR}/hello.c"
  BIN="${TMPDIR}/hello"
  cat > "${SRC}" <<'EOF'
#include <stdio.h>
int main(void) { printf("hello hacklab\n"); return 0; }
EOF

  if ! gcc -O0 -g -o "${BIN}" "${SRC}"; then
    echo "could not compile test binary — skipping smoke test"
    FAIL=1
  else
    PROJ="${TMPDIR}/proj"
    mkdir -p "${PROJ}"
    LOG="${TMPDIR}/ghidra.log"
    echo "Importing test binary with analyzeHeadless ..."
    if analyzeHeadless "${PROJ}" smoke -import "${BIN}" -overwrite >"${LOG}" 2>&1; then
      echo "Ghidra headless import: ok"
      # Confirm a project was actually created (not just a clean exit code).
      if ls "${PROJ}"/*.rep >/dev/null 2>&1 || ls "${PROJ}"/*.gpr >/dev/null 2>&1; then
        echo "Ghidra project created: ok"
      else
        echo "Ghidra project not found after import: FAILED"
        FAIL=1
      fi
    else
      echo "Ghidra headless import: FAILED — last log lines:"
      tail -n 25 "${LOG}"
      FAIL=1
    fi
  fi
fi

# ---------------------------------------------------------------------------------
printf '\n'
if [ "${FAIL}" -eq 0 ]; then
  echo "✅ all required tools present."
  exit 0
else
  echo "❌ verification failed — see MISSING/FAILED rows above."
  exit 1
fi
