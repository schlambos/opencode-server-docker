#!/usr/bin/env bash
# Entrypoint: prepare persistent /config, start sshd, exec OpenCode server.
set -euo pipefail

log() { echo "[opencode-container] $*"; }

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

cd /config/workspace
log "Starting OpenCode server on ${HOSTNAME_BIND}:${PORT} (cwd: /config/workspace)"
exec opencode serve --hostname "${HOSTNAME_BIND}" --port "${PORT}"
