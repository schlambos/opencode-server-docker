# OpenCode Server + OpenSSH — unRAID-friendly container
#
# - OpenCode launches in server mode on container start
# - OpenSSH listens on port 22 (root login, password auth)
# - ALL OpenCode state persists to /config (map to unRAID appdata)

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies:
# - openssh-server : inbound SSH
# - git            : required by OpenCode (VCS integration, snapshots)
# - ripgrep        : used by OpenCode file-search tools
# - curl/ca-certs  : install script + provider HTTPS calls
# - tar            : required by the install script
# - procps/nano    : quality of life when SSH'd in
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server \
      git \
      ripgrep \
      curl \
      ca-certificates \
      tar \
      unzip \
      procps \
      nano \
    && rm -rf /var/lib/apt/lists/*

# Install OpenCode binary into the image (NOT the persistent volume).
# The install script drops the binary under $HOME (e.g. ~/.opencode/bin);
# move it to /usr/local/bin so it lives in the image and is always on PATH,
# while /config (mounted volume) keeps only your data.
RUN curl -fsSL https://opencode.ai/install | bash \
    && BIN="$(find /root -type f -name opencode | head -1)" \
    && test -n "$BIN" \
    && mv "$BIN" /usr/local/bin/opencode \
    && chmod +x /usr/local/bin/opencode \
    && rm -rf /root/.opencode \
    && opencode --version

# sshd: allow root login with password (password is set at runtime
# from the ROOT_PASSWORD env var by the entrypoint).
RUN mkdir -p /run/sshd \
    && sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    # Host keys are persisted under /config/ssh (see entrypoint)
    && sed -ri 's|^#?HostKey /etc/ssh/|HostKey /config/ssh/|' /etc/ssh/sshd_config

# /config is the single persistent volume. HOME points at it, so
# OpenCode's XDG-style dirs all land inside it automatically:
#   /config/.config/opencode       -> settings, agents, plugins
#   /config/.local/share/opencode  -> auth.json, sessions, history, logs
#   /config/.cache/opencode        -> provider package cache
ENV HOME=/config \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_PORT=4096 \
    OPENCODE_HOSTNAME=0.0.0.0

# Make root's home /config so SSH sessions land in the same state dir
RUN usermod -d /config root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/config"]
EXPOSE 22 4096

ENTRYPOINT ["/entrypoint.sh"]
