#!/bin/sh
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Create group and user with matching UID/GID
groupadd -g "$HOST_GID" -o sandbox 2>/dev/null || true
useradd -u "$HOST_UID" -g "$HOST_GID" -o -m -d /home/sandbox -s /bin/sh sandbox 2>/dev/null || true

# Ensure home directory structure exists for mounts
mkdir -p /home/sandbox/.gnupg /home/sandbox/.config /home/sandbox/.local/share
chmod 700 /home/sandbox/.gnupg
chown "$HOST_UID:$HOST_GID" /home/sandbox /home/sandbox/.gnupg /home/sandbox/.config /home/sandbox/.local /home/sandbox/.local/share

# Execute as sandbox user
cd /workspace
exec gosu sandbox "$@"
