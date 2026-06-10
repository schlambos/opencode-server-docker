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
3. Set **Root Password (SSH)**, confirm the appdata path (`/mnt/user/appdata/opencode`), click **Apply**. unRAID pulls the image from GHCR and starts it.

## Run — docker compose

```bash
docker compose up -d
```

Edit `docker-compose.yml` first: change `ROOT_PASSWORD`, adjust the volume path.

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
