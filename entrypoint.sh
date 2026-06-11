#!/usr/bin/env bash
# Entrypoint: prepare persistent /config, start sshd, exec OpenCode server.
set -euo pipefail

log() { echo "[opencode-container] $*"; }

CHISL_PLUGIN_OPT="/opt/chisl-opencode-plugin"
CHISL_PLUGIN_FILE="file://${CHISL_PLUGIN_OPT}/dist/index.js"

# Seed the bundled Chisl plugin into OpenCode's Bun cache and rewrite any
# npm-style @chisl/chisl-opencode-plugin entry to the bundled file:// path
# (the package is not on the public npm registry).
seed_chisl_plugin() {
  if [[ ! -f "${CHISL_PLUGIN_OPT}/dist/index.js" ]]; then
    return 0
  fi

  local cache="/config/.cache/opencode/node_modules/@chisl/chisl-opencode-plugin"
  local image_ver="${CHISL_PLUGIN_OPT}/.package-version"
  local cache_ver="${cache}/.package-version"

  if [[ ! -f "${cache}/dist/index.js" ]] \
     || ! cmp -s "${image_ver}" "${cache_ver}" 2>/dev/null; then
    log "Seeding @chisl/chisl-opencode-plugin into OpenCode plugin cache ..."
    mkdir -p "$(dirname "${cache}")"
    rm -rf "${cache}"
    cp -a "${CHISL_PLUGIN_OPT}" "${cache}"
    [[ -f "${image_ver}" ]] && cp "${image_ver}" "${cache_ver}"
  fi

  local cfg
  for cfg in /config/.config/opencode/opencode.jsonc /config/.config/opencode/opencode.json; do
    [[ -f "${cfg}" ]] || continue
    if grep -q '"@chisl/chisl-opencode-plugin"' "${cfg}"; then
      sed -i 's|"@chisl/chisl-opencode-plugin"|"'"${CHISL_PLUGIN_FILE}"'"|g' "${cfg}"
      log "Rewrote @chisl/chisl-opencode-plugin -> ${CHISL_PLUGIN_FILE} in ${cfg}"
    fi
  done
}

# ---------------------------------------------------------------------------
# 1. Persistent directory layout under /config (unRAID appdata mount)
# ---------------------------------------------------------------------------
mkdir -p \
  /config/.config/opencode \
  /config/.local/share/opencode \
  /config/.cache/opencode \
  /config/ssh \
  /config/workspace

# ---------------------------------------------------------------------------
# 2. Root password for SSH (from ROOT_PASSWORD env var)
# ---------------------------------------------------------------------------
if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  echo "root:${ROOT_PASSWORD}" | chpasswd
  log "Root password set from ROOT_PASSWORD."
else
  log "WARNING: ROOT_PASSWORD not set — SSH password login will not work."
  log "         Set the ROOT_PASSWORD variable on the container."
fi

# ---------------------------------------------------------------------------
# 3. SSH host keys — persisted in /config/ssh so the host fingerprint
#    survives container rebuilds/updates (no scary MITM warnings).
# ---------------------------------------------------------------------------
if ! ls /config/ssh/ssh_host_*_key >/dev/null 2>&1; then
  log "Generating SSH host keys into /config/ssh ..."
  ssh-keygen -t rsa     -f /config/ssh/ssh_host_rsa_key     -N '' -q
  ssh-keygen -t ecdsa   -f /config/ssh/ssh_host_ecdsa_key   -N '' -q
  ssh-keygen -t ed25519 -f /config/ssh/ssh_host_ed25519_key -N '' -q
fi
chmod 600 /config/ssh/ssh_host_*_key

# ---------------------------------------------------------------------------
# 4. Start OpenSSH daemon (background)
# ---------------------------------------------------------------------------
mkdir -p /run/sshd
/usr/sbin/sshd -e
log "sshd started on port 22."

# ---------------------------------------------------------------------------
# 5. Launch OpenCode in server mode (foreground = container main process)
# ---------------------------------------------------------------------------
PORT="${OPENCODE_PORT:-4096}"
HOSTNAME_BIND="${OPENCODE_HOSTNAME:-0.0.0.0}"

if [[ -z "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
  log "NOTE: OPENCODE_SERVER_PASSWORD not set — the OpenCode API is"
  log "      unauthenticated. Fine on a trusted LAN; set it otherwise."
fi

if command -v bun >/dev/null 2>&1; then
  log "Bun $(bun --version) available at $(command -v bun)."
else
  log "WARNING: bun not found on PATH — OpenCode npm plugin installs will fail."
fi

if [[ -n "${AIONCORE_URL:-}" && -n "${AIONCORE_TOKEN:-}" ]]; then
  log "Chisl dial-back configured via AIONCORE_URL / AIONCORE_TOKEN env vars."
elif [[ -n "${AIONCORE_URL:-}" || -n "${AIONCORE_TOKEN:-}" ]]; then
  log "WARNING: Set both AIONCORE_URL and AIONCORE_TOKEN (Unraid template or opencode.jsonc)."
else
  log "NOTE: AIONCORE_URL / AIONCORE_TOKEN unset — set Unraid template vars or opencode.jsonc plugin tuple."
fi

seed_chisl_plugin

cd /config/workspace
log "Starting OpenCode server on ${HOSTNAME_BIND}:${PORT} (cwd: /config/workspace)"
exec opencode serve --hostname "${HOSTNAME_BIND}" --port "${PORT}"
