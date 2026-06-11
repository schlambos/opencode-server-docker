#!/usr/bin/env bash
# Entrypoint: prepare persistent /config, start sshd, exec OpenCode server.
set -euo pipefail

log() { echo "[opencode-container] $*"; }
warn() { echo "[opencode-container] WARNING: $*" >&2; }

CHISL_PLUGIN_OPT="/opt/chisl-opencode-plugin"
CHISL_PLUGIN_FILE="file://${CHISL_PLUGIN_OPT}/dist/index.js"
CHISL_ENV_FILE="/config/.config/opencode/chisl.env"

# ---------------------------------------------------------------------------
# Chisl dial-back credentials — Docker env, persistent file, or both.
# Unraid often fails to inject NEW template variables into existing containers;
# SSH login shells also do not inherit Docker -e vars. We sync to chisl.env and
# source it for interactive shells via /etc/profile.d/chisl-env.sh.
# ---------------------------------------------------------------------------

load_chisl_connection_env() {
  local from_file_url="" from_file_token=""
  local from_docker_url="${AIONCORE_URL:-}"
  local from_docker_token="${AIONCORE_TOKEN:-}"

  if [[ -f "${CHISL_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a && source "${CHISL_ENV_FILE}" && set +a
    from_file_url="${AIONCORE_URL:-}"
    from_file_token="${AIONCORE_TOKEN:-}"
    log "Loaded Chisl credentials from ${CHISL_ENV_FILE} (token len=${#from_file_token})."
  fi

  # Docker / Unraid template wins when both are set; file fills gaps.
  if [[ -n "${from_docker_url}" ]]; then
    export AIONCORE_URL="${from_docker_url}"
  elif [[ -n "${from_file_url}" ]]; then
    export AIONCORE_URL="${from_file_url}"
  fi
  if [[ -n "${from_docker_token}" ]]; then
    export AIONCORE_TOKEN="${from_docker_token}"
  elif [[ -n "${from_file_token}" ]]; then
    export AIONCORE_TOKEN="${from_file_token}"
  fi

  if [[ -n "${AIONCORE_URL:-}" && -n "${AIONCORE_TOKEN:-}" ]]; then
    mkdir -p "$(dirname "${CHISL_ENV_FILE}")"
    umask 077
    cat > "${CHISL_ENV_FILE}" <<EOF
# Managed by opencode-server entrypoint — edit on the Unraid appdata share if
# template env vars are not applied. Restart the container after changes.
AIONCORE_URL=${AIONCORE_URL}
AIONCORE_TOKEN=${AIONCORE_TOKEN}
EOF
    chmod 600 "${CHISL_ENV_FILE}"
    if [[ -n "${from_docker_url}" || -n "${from_docker_token}" ]]; then
      log "Synced Chisl credentials from container env -> ${CHISL_ENV_FILE}"
    fi
  elif [[ ! -f "${CHISL_ENV_FILE}" ]]; then
    warn "Chisl credentials missing. Set Unraid template vars AIONCORE_URL / AIONCORE_TOKEN,"
    warn "or create ${CHISL_ENV_FILE} on the appdata share (see README), then restart."
  fi

  mkdir -p /etc/profile.d
  cat > /etc/profile.d/chisl-env.sh <<'EOF'
# Source persistent Chisl dial-back credentials for SSH sessions.
if [[ -f /config/.config/opencode/chisl.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /config/.config/opencode/chisl.env
  set +a
fi
EOF
  chmod 644 /etc/profile.d/chisl-env.sh
}

# ---------------------------------------------------------------------------
# Chisl plugin — bundle check, cache seed, config rewrite, plugins/ loader
# ---------------------------------------------------------------------------

log_chisl_bundle_status() {
  if [[ ! -f "${CHISL_PLUGIN_OPT}/dist/index.js" ]]; then
    warn "Bundled Chisl plugin missing at ${CHISL_PLUGIN_OPT}/dist/index.js."
    warn "Rebuild the image (ghcr.io/schlambos/opencode-server:latest) — an old image has no plugin."
    return 1
  fi
  local ver="unknown"
  [[ -f "${CHISL_PLUGIN_OPT}/.package-version" ]] && ver="$(cat "${CHISL_PLUGIN_OPT}/.package-version")"
  log "Bundled Chisl plugin OK (version ${ver}) at ${CHISL_PLUGIN_OPT}/dist/index.js"
  return 0
}

# OpenCode discovers /config/.config/opencode/plugins/*.mjs automatically.
# This loader is the most reliable path when opencode.jsonc is incomplete.
install_chisl_plugin_loader() {
  [[ -f "${CHISL_PLUGIN_OPT}/dist/index.js" ]] || return 0

  local plugdir="/config/.config/opencode/plugins"
  local loader="${plugdir}/chisl.mjs"
  local stamp="${loader}.version"
  local want_ver="unknown"
  [[ -f "${CHISL_PLUGIN_OPT}/.package-version" ]] && want_ver="$(cat "${CHISL_PLUGIN_OPT}/.package-version")"

  if [[ -f "${loader}" && -f "${stamp}" && "$(cat "${stamp}")" == "${want_ver}" ]]; then
    log "Chisl plugin loader already installed (${loader})."
    return 0
  fi

  mkdir -p "${plugdir}"
  cat > "${loader}" <<EOF
// Installed by opencode-server entrypoint — re-exports the bundled Chisl plugin.
// Reads AIONCORE_URL / AIONCORE_TOKEN from the container env when the jsonc tuple omits them.
export { default } from "${CHISL_PLUGIN_FILE}";
EOF
  echo "${want_ver}" > "${stamp}"
  log "Installed Chisl plugin loader at ${loader} (OpenCode auto-discovers plugins/*.mjs)."
}

ensure_config_package_json() {
  local pkg="/config/.config/opencode/package.json"
  if [[ ! -f "${pkg}" ]]; then
    cat > "${pkg}" <<'EOF'
{
  "dependencies": {
    "@opencode-ai/plugin": "1.16.2"
  }
}
EOF
    log "Created ${pkg} for OpenCode plugin runtime dependencies."
  fi
  if command -v bun >/dev/null 2>&1 && [[ -f "${pkg}" ]]; then
    (cd /config/.config/opencode && bun install --silent 2>/dev/null) \
      && log "Bun install OK in /config/.config/opencode" \
      || warn "bun install in /config/.config/opencode failed — plugin hooks may not load."
  fi
}

# Seed bundled plugin into Bun cache; rewrite npm-style name to file:// in jsonc.
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
    if grep -qE '@chisl/chisl-opencode-plugin|chisl-opencode-plugin' "${cfg}" 2>/dev/null; then
      if grep -q '"@chisl/chisl-opencode-plugin"' "${cfg}"; then
        sed -i 's|"@chisl/chisl-opencode-plugin"|"'"${CHISL_PLUGIN_FILE}"'"|g' "${cfg}"
        log "Rewrote @chisl/chisl-opencode-plugin -> ${CHISL_PLUGIN_FILE} in ${cfg}"
      else
        log "Chisl plugin already referenced in ${cfg} (no npm-name rewrite needed)."
      fi
    fi
  done
}

# When Unraid env vars are set but opencode.jsonc has no chisl reference, append tuple.
ensure_chisl_plugin_in_config() {
  if [[ -z "${AIONCORE_URL:-}" || -z "${AIONCORE_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ ! -f "${CHISL_PLUGIN_OPT}/dist/index.js" ]]; then
    return 0
  fi

  local cfg="/config/.config/opencode/opencode.jsonc"
  [[ -f "${cfg}" ]] || cfg="/config/.config/opencode/opencode.json"
  [[ -f "${cfg}" ]] || return 0

  if grep -qE 'chisl-opencode-plugin|/opt/chisl-opencode-plugin' "${cfg}" 2>/dev/null; then
    return 0
  fi

  log "No Chisl entry in ${cfg}; appending file:// plugin tuple (url + token from env) ..."
  if ! command -v bun >/dev/null 2>&1; then
    warn "bun missing — cannot auto-append Chisl plugin to ${cfg}. Use plugins/chisl.mjs loader instead."
    return 0
  fi

  AIONCORE_URL="${AIONCORE_URL}" AIONCORE_TOKEN="${AIONCORE_TOKEN}" \
    CHISL_PLUGIN_FILE="${CHISL_PLUGIN_FILE}" CONFIG_PATH="${cfg}" \
    bun -e '
      const fs = require("fs");
      const path = process.env.CONFIG_PATH;
      const pluginPath = process.env.CHISL_PLUGIN_FILE;
      const url = (process.env.AIONCORE_URL || "").replace(/\/?$/, "/");
      const token = process.env.AIONCORE_TOKEN || "";
      let raw = fs.readFileSync(path, "utf8");
      const stripped = raw
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .replace(/\/\/.*$/gm, "")
        .replace(/,\s*([}\]])/g, "$1");
      const cfg = JSON.parse(stripped);
      cfg.plugin = cfg.plugin || [];
      cfg.plugin.push([pluginPath, { url, token }]);
      fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
    ' && log "Appended Chisl plugin tuple to ${cfg}" \
    || warn "Failed to append Chisl plugin to ${cfg} — rely on plugins/chisl.mjs + env vars."
}

log_chisl_config_notes() {
  log "NOTE: url/token inside opencode.jsonc plugin tuples override AIONCORE_URL / AIONCORE_TOKEN."
  log "      Chisl UI 'connected' requires plugin hello with 6 hooks (v0.2.0) + SSE — not manual curl."
  local cfg
  for cfg in /config/.config/opencode/opencode.jsonc /config/.config/opencode/opencode.json; do
    [[ -f "${cfg}" ]] || continue
    if grep -qE 'chisl-opencode-plugin|/opt/chisl-opencode-plugin' "${cfg}" 2>/dev/null; then
      log "Found Chisl reference in ${cfg}"
    fi
  done
}

probe_aioncore_reachability() {
  if [[ -z "${AIONCORE_URL:-}" || -z "${AIONCORE_TOKEN:-}" ]]; then
    return 0
  fi
  local base="${AIONCORE_URL%/}/"
  local code
  # Port 64921 is the AionCore *plugin* server — not OpenCode. It has no
  # /global/health (that path is OpenCode-only). Probe /plugin/hello instead.
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 \
    -X POST \
    -H "Authorization: Bearer ${AIONCORE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"protocolVersion":1,"pluginVersion":"0.0.0","hooks":[]}' \
    "${base}plugin/hello" 2>/dev/null)"
  if [[ -z "${code}" ]]; then
    code="000"
  fi
  if [[ "${code}" == "200" ]]; then
    log "AionCore plugin channel reachable (${base}plugin/hello -> HTTP ${code})."
  elif [[ "${code}" == "401" ]]; then
    warn "AionCore plugin channel reachable but token rejected (HTTP 401 on ${base}plugin/hello)."
    warn "Re-copy the token from Chisl Install Plugin into Unraid / chisl.env / opencode.jsonc."
  elif [[ "${code}" == "000" ]]; then
    warn "Cannot reach AionCore plugin channel at ${base}plugin/hello (connection failed)."
    warn "Check LAN routing and Mac firewall on port 64921."
  else
    warn "Unexpected response from ${base}plugin/hello (HTTP ${code})."
  fi
}

prepare_chisl_plugin() {
  log_chisl_bundle_status || true
  ensure_config_package_json
  seed_chisl_plugin
  install_chisl_plugin_loader
  ensure_chisl_plugin_in_config
  log_chisl_config_notes
  probe_aioncore_reachability
}

# ---------------------------------------------------------------------------
# 1. Persistent directory layout under /config (unRAID appdata mount)
# ---------------------------------------------------------------------------
mkdir -p \
  /config/.config/opencode \
  /config/.config/opencode/plugins \
  /config/.local/share/opencode \
  /config/.cache/opencode \
  /config/ssh \
  /config/workspace

load_chisl_connection_env

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
  warn "bun not found on PATH — OpenCode npm plugin installs will fail."
fi

if [[ -n "${AIONCORE_URL:-}" && -n "${AIONCORE_TOKEN:-}" ]]; then
  log "Chisl dial-back env: AIONCORE_URL=${AIONCORE_URL} (token length ${#AIONCORE_TOKEN})."
elif [[ -n "${AIONCORE_URL:-}" || -n "${AIONCORE_TOKEN:-}" ]]; then
  warn "Set both AIONCORE_URL and AIONCORE_TOKEN (Unraid template or opencode.jsonc tuple)."
else
  log "NOTE: AIONCORE_URL / AIONCORE_TOKEN unset — set Unraid template vars or opencode.jsonc plugin tuple."
fi

prepare_chisl_plugin

cd /config/workspace
log "Starting OpenCode server on ${HOSTNAME_BIND}:${PORT} (cwd: /config/workspace)"
exec opencode serve --hostname "${HOSTNAME_BIND}" --port "${PORT}"
