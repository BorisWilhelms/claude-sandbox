#!/bin/sh
set -e

IMAGE_NAME="claude-sandbox:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Detect container runtime ---
detect_runtime() {
    if [ -n "$CONTAINER_ID" ]; then
        # Inside distrobox — check what's on the host
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
    # Bake the repo path into the installed copy so builds work from anywhere
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

cmd_run() {
    # Build if image doesn't exist
    if ! image_exists; then
        cmd_build
    fi

    # --- Resolve host paths ---
    # When running inside distrobox, ~ points to the host home (distrobox shares it).
    # We need the real host paths for docker bind-mounts.
    HOST_HOME="$HOME"
    HOST_PWD="$(pwd)"

    # --- Assemble mounts ---
    MOUNTS=""
    MOUNTS="$MOUNTS -v $HOST_PWD:/workspace"
    MOUNTS="$MOUNTS -v $HOST_HOME/.claude:/home/sandbox/.claude"
    MOUNTS="$MOUNTS -v $HOST_HOME/.gitconfig:/home/sandbox/.gitconfig:ro"

    # Optional mounts (only if source exists)
    [ -d "$HOST_HOME/.config/nvim" ] && \
        MOUNTS="$MOUNTS -v $HOST_HOME/.config/nvim:/home/sandbox/.config/nvim:ro"
    [ -f "$HOST_HOME/.tmux.conf" ] && \
        MOUNTS="$MOUNTS -v $HOST_HOME/.tmux.conf:/home/sandbox/.tmux.conf:ro"
    [ -d "$HOST_HOME/.local/share/nvim" ] && \
        MOUNTS="$MOUNTS -v $HOST_HOME/.local/share/nvim:/home/sandbox/.local/share/nvim"

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
    ENV_VARS="$ENV_VARS -e HOST_UID=$(id -u) -e HOST_GID=$(id -g)"
    [ -n "$SSH_AUTH_SOCK" ] && \
        ENV_VARS="$ENV_VARS -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
    [ -n "$ANTHROPIC_API_KEY" ] && \
        ENV_VARS="$ENV_VARS -e ANTHROPIC_API_KEY"
    if [ -n "$GPG_SOCK" ] && [ -S "$GPG_SOCK" ]; then
        ENV_VARS="$ENV_VARS -e GPG_AGENT_INFO=/home/sandbox/.gnupg/S.gpg-agent"
    fi

    # --- Run ---
    RUN_CMD="$RUNTIME run -it --rm $MOUNTS $ENV_VARS $IMAGE_NAME"

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
