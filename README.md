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

After restart, the Chisl UI should show **6 hooks active** without manual
`curl` — and stay connected via the plugin's SSE loop.

**Bun** is installed at `/usr/local/bun/bin/bun` (on `PATH`) for OpenCode's
npm plugin installs and for debugging from SSH (`bun --version`).

**Local image build with a working-tree copy** (optional — CI fetches from
GitHub automatically):

```bash
./scripts/vendor-chisl-plugin.sh   # copies from ~/chisl-full/AionUi by default
docker compose build
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
