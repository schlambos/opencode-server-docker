#!/usr/bin/env bash
# Copy the Chisl OpenCode plugin into the Docker build context.
# Refresh the vendored plugin committed under plugins/chisl-opencode-plugin.
# CI builds from that tree — run this script before bumping the plugin version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${CHISL_PLUGIN_SRC:-$HOME/chisl-full/AionUi/packages/opencode-plugin}"
DEST="$ROOT/plugins/chisl-opencode-plugin"

if [[ ! -f "$SRC/package.json" ]]; then
  echo "error: Chisl plugin not found at $SRC" >&2
  echo "Set CHISL_PLUGIN_SRC to packages/opencode-plugin in your AionUi checkout." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
rsync -a \
  --exclude node_modules \
  --exclude '.turbo' \
  "$SRC/" "$DEST/"

VERSION="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$DEST/package.json" | head -1)"
echo "$VERSION" >"$DEST/.package-version"
echo "Vendored @chisl/chisl-opencode-plugin@${VERSION} from $SRC -> $DEST"
