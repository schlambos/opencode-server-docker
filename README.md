# OpenCode Server — Docker container for unRAID

A container that:

1. **Launches OpenCode in server mode on start** — `opencode serve --hostname 0.0.0.0 --port 4096` as the container's main process (PID 1 via `exec`; container stops if the server dies, so unRAID's restart policy can recover it).
2. **Runs OpenSSH on port 22** — root login with password auth (`ROOT_PASSWORD` env var). SSH host keys are persisted so the fingerprint never changes across rebuilds.
3. **Persists ALL OpenCode state outside the container** — the container's `HOME` is `/config`, so every path OpenCode writes to lands on your appdata share:

| Inside container                 | What it holds                                       |
| -------------------------------- | --------------------------------------------------- |
| `/config/.config/opencode/`      | `opencode.json`, agents, commands, plugins, themes  |
| `/config/.local/share/opencode/` | `auth.json` (API keys/OAuth), sessions, history, logs |
| `/config/.cache/opencode/`       | downloaded provider packages                        |
| `/config/ssh/`                   | persistent SSH host keys                            |
| `/config/workspace/`             | default working directory for projects              |

## Image

Prebuilt and published automatically by GitHub Actions:

```
ghcr.io/schlambos/opencode-server:latest
```

Rebuilt weekly to pick up new OpenCode releases. No local building required — unRAID pulls it like any other container, and the standard unRAID **update** button pulls new versions.

## Run — unRAID

1. Open the unRAID **web terminal** (the `>_` icon, top-right of the GUI) and run this one command to install the template:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/schlambos/opencode-server-docker/main/my-opencode.xml \
     -o /boot/config/plugins/dockerMan/templates-user/my-opencode.xml
   ```

2. **Docker** tab → **Add Container** → pick **opencode** from the Template dropdown (under "User templates").
3. Set **Root Password (SSH)**, **Chisl AionCore URL** (`http://YOUR_CHISL_HOST:64921/`), **Chisl AionCore Token** (from Chisl Install Plugin), confirm the appdata path (`/mnt/user/appdata/opencode`), click **Apply**. unRAID pulls the image from GHCR and starts it.

   Existing containers: **Edit** → add/update the Chisl variables → **Apply** → **Restart**.

## Run — docker compose

```bash
docker compose up -d
```

Edit `docker-compose.yml` first: change `ROOT_PASSWORD`, adjust the volume path.

## Chisl plugin (bundled)

The image ships with `@chisl/chisl-opencode-plugin` pre-built at
`/opt/chisl-opencode-plugin`. OpenCode normally installs npm plugins with Bun
into `/config/.cache/opencode/node_modules/`, but the Chisl package is **not on
the public npm registry**, so a plain `"@chisl/chisl-opencode-plugin"` entry in
`opencode.jsonc` silently fails to load.

On every container start the entrypoint:

1. Seeds the bundled plugin into `/config/.cache/opencode/node_modules/@chisl/…`
2. Rewrites any `"@chisl/chisl-opencode-plugin"` entry in `opencode.jsonc` to
   `file:///opt/chisl-opencode-plugin/dist/index.js` (your `url` / `token`
   tuple is preserved)
3. Installs `/config/.config/opencode/plugins/chisl.mjs` so OpenCode
   auto-discovers the plugin even when `opencode.jsonc` is incomplete
4. Runs `bun install` in `/config/.config/opencode` for `@opencode-ai/plugin`
5. Probes `AIONCORE_URL/plugin/hello` from inside the container (logs pass/fail)

Add the plugin to `/config/.config/opencode/opencode.jsonc` (see
`config/opencode.chisl-snippet.jsonc` for a full example):

```jsonc
"plugin": [
  [
    "file:///opt/chisl-opencode-plugin/dist/index.js",
    {
      "url": "http://YOUR_CHISL_HOST:64921/",
      "token": "TOKEN_FROM_CHISL_INSTALL_PLUGIN"
    }
  ]
]
```

Set **`AIONCORE_URL`** and **`AIONCORE_TOKEN`** on the container (Unraid
template fields **Chisl AionCore URL** / **Chisl AionCore Token**) — values
from the Chisl **Install Plugin** card. The plugin reads these env vars when
the `opencode.jsonc` tuple omits `url` / `token`. Tuple options take
precedence over env.

**Unraid gotcha:** template variables added in a newer image are **not**
applied to an existing container until you **Edit** the container (fields must
appear), **Apply**, and **restart**. If values still do not reach OpenCode,
create **`/mnt/user/appdata/opencode/.config/opencode/chisl.env`** on the host
(see `config/chisl.env.example`), `chmod 600`, restart. The entrypoint loads
that file and syncs it when Docker env vars work.

After restart, the Chisl UI should show **6 hooks active** without manual
`curl` — and stay connected via the plugin's SSE loop.

### Troubleshooting "Waiting for plugin"

Chisl is connected only when AionCore logs show:

```
plugin hello ... plugin_version=0.2.0 hook_count=6
```

and the plugin keeps an SSE stream open. If you see `hook_count=0` or
`plugin_version=0.1.0`, that is **not** the bundled plugin (often a manual
`curl` test or a failed npm install).

**Inside the container (SSH):**

```bash
# Bundled plugin present?
ls -la /opt/chisl-opencode-plugin/dist/index.js
cat /opt/chisl-opencode-plugin/.package-version   # expect 0.2.0

# Auto-loader installed?
cat /config/.config/opencode/plugins/chisl.mjs

# Env vars — SSH echo is WRONG for Docker -e vars; check PID 1 / chisl.env:
tr '\0' '\n' < /proc/1/environ | grep -E '^AIONCORE_'
cat /config/.config/opencode/chisl.env 2>/dev/null | sed 's/AIONCORE_TOKEN=.*/AIONCORE_TOKEN=***masked***/'
source /etc/profile.d/chisl-env.sh 2>/dev/null || true
echo "URL=$AIONCORE_URL"
echo "TOKEN_LEN=${#AIONCORE_TOKEN}"

# Reach Chisl plugin channel? (/global/health is OpenCode-only — wrong port)
source /etc/profile.d/chisl-env.sh 2>/dev/null || true
curl -sS -m 8 -X POST \
  -H "Authorization: Bearer $AIONCORE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"protocolVersion":1,"pluginVersion":"0.2.0","hooks":["event"]}' \
  "${AIONCORE_URL%/}/plugin/hello"

# OpenCode plugin errors
ls -lt /config/.local/share/opencode/log/ | head
```

**Common fixes:**

1. **Pull the latest image** — Docker → Check for Updates → Apply. Startup
   logs must include `Bundled Chisl plugin OK (version 0.2.0)`.
2. **Token mismatch** — Copy token from Chisl **Install Plugin** again into
   Unraid **Chisl AionCore Token** *and* any `opencode.jsonc` tuple (tuple
   wins over env).
3. **Stale tuple in jsonc** — If you rotated the token in Chisl but left the
   old token in `opencode.jsonc`, update or remove the tuple so env vars apply.
4. **Mac firewall** — Allow inbound TCP **64921** from `192.168.0.5`.
5. **Do not** run manual `curl .../plugin/hello` for testing — it fakes
   "connected" for 60 seconds with 0 hooks and hides the real problem.

**Bun** is installed at `/usr/local/bun/bin/bun` (on `PATH`) for OpenCode's
npm plugin installs and for debugging from SSH (`bun --version`).

**Updating the vendored plugin** (required before bumping plugin version in the
image — CI builds from `plugins/chisl-opencode-plugin/` in this repo, not from
GitHub):

```bash
./scripts/vendor-chisl-plugin.sh   # copies from ~/chisl-full/AionUi by default
git add plugins/chisl-opencode-plugin
docker compose build               # optional local verify
```

## First-time setup

SSH in and authenticate OpenCode once — credentials persist in appdata:

```bash
ssh root@YOUR_SERVER -p 2222
opencode auth login
```

You can also run the full OpenCode TUI in that SSH session (`cd /config/workspace && opencode`). The server API is at `http://YOUR_SERVER:4096`.

## Security notes

- The OpenCode API has **no auth by default**. Set `OPENCODE_SERVER_PASSWORD` if the port is reachable beyond your trusted LAN (basic auth, username `opencode`).
- Do **not** expose port 22 or 4096 of this container to the internet.
- `auth.json` (API keys) lives in appdata — protect that share accordingly.

## Updating OpenCode

The image is rebuilt weekly by CI with the latest OpenCode release (in-container autoupdate is disabled, as is best practice). On unRAID: Docker tab → **Check for Updates** → **apply update** on the opencode container. Your data in `/config` is untouched.
