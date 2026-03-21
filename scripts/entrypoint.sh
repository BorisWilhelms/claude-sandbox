#!/bin/sh
set -e

# Ensure home directory structure exists
mkdir -p "$HOME/.gnupg" "$HOME/.config" "$HOME/.local/share" 2>/dev/null || true
chmod 700 "$HOME/.gnupg" 2>/dev/null || true

cd /workspace
exec "$@"
