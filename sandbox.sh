#!/bin/sh
set -e

IMAGE_NAME="claude-sandbox:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/sandbox.conf"

# --- Detect container runtime ---
detect_runtime() {
    if [ -n "$CONTAINER_ID" ]; then
        if distrobox-host-exec sh -c "command -v docker" >/dev/null 2>&1; then
            echo "docker"
        elif distrobox-host-exec sh -c "command -v podman" >/dev/null 2>&1; then
            echo "podman"
        else
            echo "ERROR: Neither docker nor podman found on host" >&2
            exit 1
        fi
    else
        if command -v docker >/dev/null 2>&1; then
            echo "docker"
        elif command -v podman >/dev/null 2>&1; then
            echo "podman"
        else
            echo "ERROR: Neither docker nor podman found" >&2
            exit 1
        fi
    fi
}

RUNTIME="$(detect_runtime)"

# --- Subcommands ---

cmd_install() {
    REPO_DIR="$SCRIPT_DIR"
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$REPO_DIR\"|" "$0" > "$HOME/.local/bin/claude-sandbox"
    chmod +x "$HOME/.local/bin/claude-sandbox"
    echo "Installed to ~/.local/bin/claude-sandbox (build context: $REPO_DIR)"
}

cmd_build() {
    echo "Building $IMAGE_NAME..."
    if [ -n "$CONTAINER_ID" ]; then
        distrobox-host-exec $RUNTIME build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    else
        $RUNTIME build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    fi
}

image_exists() {
    if [ -n "$CONTAINER_ID" ]; then
        distrobox-host-exec $RUNTIME image inspect "$IMAGE_NAME" >/dev/null 2>&1
    else
        $RUNTIME image inspect "$IMAGE_NAME" >/dev/null 2>&1
    fi
}

# --- Parse config file into mounts ---
parse_mounts() {
    HOST_HOME="$HOME"

    if [ ! -f "$CONF_FILE" ]; then
        echo "WARNING: No sandbox.conf found at $CONF_FILE" >&2
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        case "$line" in
            \#*|"") continue ;;
        esac

        # Parse fields: host_path [container_path] [rw]
        host_path=""
        container_path=""
        mode="ro"

        # Check if last field is "rw"
        last_field=$(echo "$line" | awk '{print $NF}')
        if [ "$last_field" = "rw" ]; then
            mode="rw"
            # Remove trailing "rw"
            line=$(echo "$line" | sed 's/ *rw$//')
        fi

        host_path=$(echo "$line" | awk '{print $1}')
        container_path=$(echo "$line" | awk '{print $2}')

        # Expand ~ to $HOME
        host_path=$(echo "$host_path" | sed "s|^~|$HOST_HOME|")

        # Skip if source doesn't exist
        if [ ! -e "$host_path" ]; then
            continue
        fi

        # Default container path: mirror under /home/sandbox/
        if [ -z "$container_path" ]; then
            # Strip $HOME prefix, prepend /home/sandbox
            rel_path=$(echo "$host_path" | sed "s|^$HOST_HOME/||")
            container_path="/home/sandbox/$rel_path"
        else
            container_path=$(echo "$container_path" | sed "s|^~|/home/sandbox|")
        fi

        MOUNTS="$MOUNTS -v $host_path:$container_path:$mode"
    done < "$CONF_FILE"
}

cmd_run() {
    if ! image_exists; then
        cmd_build
    fi

    HOST_HOME="$HOME"
    HOST_PWD="$(pwd)"

    # --- Assemble mounts ---
    MOUNTS=""
    MOUNTS="$MOUNTS -v $HOST_PWD:/workspace"

    # Mounts from config file
    parse_mounts

    # SSH agent
    if [ -n "$SSH_AUTH_SOCK" ]; then
        MOUNTS="$MOUNTS -v $SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
    fi

    # GPG agent
    GPG_SOCK=""
    if command -v gpgconf >/dev/null 2>&1; then
        GPG_SOCK="$(gpgconf --list-dirs agent-extra-socket 2>/dev/null || true)"
    fi
    if [ -n "$GPG_SOCK" ] && [ -S "$GPG_SOCK" ]; then
        MOUNTS="$MOUNTS -v $GPG_SOCK:/home/sandbox/.gnupg/S.gpg-agent"
    fi

    # --- Assemble env vars ---
    ENV_VARS=""
    [ -n "$SSH_AUTH_SOCK" ] && \
        ENV_VARS="$ENV_VARS -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
    [ -n "$ANTHROPIC_API_KEY" ] && \
        ENV_VARS="$ENV_VARS -e ANTHROPIC_API_KEY"
    if [ -n "$GPG_SOCK" ] && [ -S "$GPG_SOCK" ]; then
        ENV_VARS="$ENV_VARS -e GPG_AGENT_INFO=/home/sandbox/.gnupg/S.gpg-agent"
    fi

    # --- Run ---
    # --userns=keep-id maps host UID/GID 1:1 into container (podman rootless)
    RUN_CMD="$RUNTIME run -it --rm --userns=keep-id $MOUNTS $ENV_VARS $IMAGE_NAME"

    if [ -n "$CONTAINER_ID" ]; then
        exec distrobox-host-exec $RUN_CMD
    else
        exec $RUN_CMD
    fi
}

# --- Main ---

case "${1:-}" in
    install) cmd_install ;;
    build)   cmd_build ;;
    *)       cmd_run ;;
esac
