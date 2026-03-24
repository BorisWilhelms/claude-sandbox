#!/bin/sh
set -e

IMAGE_NAME="claude-sandbox:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandbox/sandbox.conf"

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
    DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-sandbox"
    mkdir -p "$DATA_DIR/scripts"
    cp "$SCRIPT_DIR/Dockerfile" "$DATA_DIR/"
    cp "$SCRIPT_DIR/scripts/entrypoint.sh" "$DATA_DIR/scripts/"
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$DATA_DIR\"|" "$0" > "$HOME/.local/bin/claude-sandbox"
    chmod +x "$HOME/.local/bin/claude-sandbox"

    # Install sandbox hooks
    mkdir -p "$HOME/.claude/hooks"
    cp "$SCRIPT_DIR/hooks/sandbox-guard.sh" "$HOME/.claude/hooks/sandbox-guard.sh"
    cp "$SCRIPT_DIR/hooks/sandbox-protect-hooks.sh" "$HOME/.claude/hooks/sandbox-protect-hooks.sh"
    chmod +x "$HOME/.claude/hooks/sandbox-guard.sh" "$HOME/.claude/hooks/sandbox-protect-hooks.sh"

    # Register hooks in settings.json if not already present
    SETTINGS="$HOME/.claude/settings.json"
    if [ -f "$SETTINGS" ]; then
        if ! grep -q "sandbox-guard" "$SETTINGS"; then
            echo "NOTE: Add the following to \"hooks.PreToolUse\" in $SETTINGS:"
            echo ""
            echo '  {'
            echo '    "matcher": "Bash",'
            echo '    "hooks": [{'
            echo '      "type": "command",'
            echo '      "command": "~/.claude/hooks/sandbox-guard.sh"'
            echo '    }]'
            echo '  },'
            echo '  {'
            echo '    "matcher": "Edit|Write",'
            echo '    "hooks": [{'
            echo '      "type": "command",'
            echo '      "command": "~/.claude/hooks/sandbox-protect-hooks.sh"'
            echo '    }]'
            echo '  }'
        fi
    else
        cat > "$SETTINGS" << 'SETTINGS_EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/sandbox-guard.sh"
          }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/sandbox-protect-hooks.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
    fi

    echo "Installed to ~/.local/bin/claude-sandbox (data: $DATA_DIR)"
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
    MOUNTS="$MOUNTS -v $HOST_PWD:$HOST_PWD"

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

    # Wayland (for clipboard access)
    if [ -n "$WAYLAND_DISPLAY" ] && [ -n "$XDG_RUNTIME_DIR" ]; then
        WAYLAND_SOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        if [ -S "$WAYLAND_SOCK" ]; then
            MOUNTS="$MOUNTS -v $WAYLAND_SOCK:/tmp/wayland-0"
        fi
    fi

    # --- Assemble env vars ---
    ENV_VARS="-e TERM=xterm-256color -e SANDBOX=1"
    if [ -n "$WAYLAND_DISPLAY" ] && [ -S "${XDG_RUNTIME_DIR:-}/$WAYLAND_DISPLAY" ]; then
        ENV_VARS="$ENV_VARS -e WAYLAND_DISPLAY=wayland-0 -e XDG_RUNTIME_DIR=/tmp"
    fi
    [ -n "$SSH_AUTH_SOCK" ] && \
        ENV_VARS="$ENV_VARS -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
    if [ -n "$GPG_SOCK" ] && [ -S "$GPG_SOCK" ]; then
        ENV_VARS="$ENV_VARS -e GPG_AGENT_INFO=/home/sandbox/.gnupg/S.gpg-agent"
    fi

    # --- Run ---
    # --userns=keep-id maps host UID/GID 1:1 into container (podman rootless)
    # --security-opt label=disable disables SELinux label enforcement for bind-mounts
    RUN_CMD="$RUNTIME run -it --rm --userns=keep-id --security-opt label=disable -w $HOST_PWD $MOUNTS $ENV_VARS $IMAGE_NAME ${CONTAINER_CMD:-}"

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
    shell)   CONTAINER_CMD="bash" ; cmd_run ;;
    *)       cmd_run ;;
esac
