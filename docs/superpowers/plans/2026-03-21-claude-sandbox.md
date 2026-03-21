# Claude Code Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker-based sandbox for running Claude Code with `--dangerously-skip-permissions`, with a wrapper script that works from both host and distrobox environments.

**Architecture:** A Dockerfile builds an Arch Linux image with dev tools and Claude Code. An entrypoint script handles UID/GID mapping at runtime. A wrapper script (`claude-sandbox`) detects the environment, builds the image if needed, assembles bind-mounts, and launches the container.

**Tech Stack:** Docker, Arch Linux, bash, gosu, Node.js/npm (Claude Code), tmux, neovim, lazygit

**Spec:** `docs/superpowers/specs/2026-03-21-claude-sandbox-design.md`

---

## File Structure

```
claude-sandbox/
├── Dockerfile              # Arch Linux image with all dev tools
├── scripts/
│   ├── entrypoint.sh       # Runtime UID/GID mapping + exec into ccode
│   └── ccode               # tmux session launcher (nvim + claude + lazygit)
└── sandbox.sh              # Wrapper script (build/run/install)
```

---

### Task 1: Create the `ccode` tmux launcher script

**Files:**
- Create: `scripts/ccode`

- [ ] **Step 1: Create the script**

```sh
#!/bin/sh
DIR_NAME=$(basename "$PWD")
HASH=$(echo "$PWD" | sha256sum | cut -c1-4)
NAME="${DIR_NAME}-${HASH}"

tmux attach -t "$NAME" || tmux \
  new-session -s "$NAME" "nvim ." \; \
  rename-window "nvim" \; \
  split-window -v \; \
  resize-pane -y 25% \; \
  select-pane -t 0 \; \
  new-window -n "claude" "claude --dangerously-skip-permissions" \; \
  new-window -n "lazygit" lazygit \; \
  select-window -t 1 \; \
  attach
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/ccode`

- [ ] **Step 3: Commit**

```bash
git add scripts/ccode
git commit -m "feat: add ccode tmux launcher script"
```

---

### Task 2: Create the entrypoint script

**Files:**
- Create: `scripts/entrypoint.sh`

- [ ] **Step 1: Create the script**

```sh
#!/bin/sh
set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Create group and user with matching UID/GID
groupadd -g "$HOST_GID" -o sandbox 2>/dev/null || true
useradd -u "$HOST_UID" -g "$HOST_GID" -o -m -d /home/sandbox -s /bin/sh sandbox 2>/dev/null || true

# Ensure home directory structure exists for mounts
mkdir -p /home/sandbox/.gnupg /home/sandbox/.config /home/sandbox/.local/share
chown "$HOST_UID:$HOST_GID" /home/sandbox /home/sandbox/.gnupg /home/sandbox/.config /home/sandbox/.local /home/sandbox/.local/share

# Execute as sandbox user
cd /workspace
exec gosu sandbox "$@"
```

The script:
1. Reads `HOST_UID`/`HOST_GID` from env (defaults to 1000)
2. Creates `sandbox` group and user with matching IDs
3. Ensures home directory structure exists (needed before bind-mounts for GPG, nvim state, etc.)
4. Drops to `sandbox` user via `gosu` and execs the given command

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/entrypoint.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "feat: add entrypoint script for runtime UID/GID mapping"
```

---

### Task 3: Create the Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM archlinux:latest

# Update system and install packages
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
      nodejs npm \
      dotnet-sdk \
      python-azure-cli \
      git base-devel \
      neovim tmux lazygit \
      && pacman -Scc --noconfirm

# Install gosu from AUR (build as temp user, install, clean up)
RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    su - builder -c "git clone https://aur.archlinux.org/gosu-bin.git /tmp/gosu-bin && cd /tmp/gosu-bin && makepkg -si --noconfirm" && \
    userdel -r builder && \
    rm /etc/sudoers.d/builder

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/ccode /usr/local/bin/ccode

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["ccode"]
```

Notes:
- `python-azure-cli` is the Arch package name for azure-cli
- `gosu-bin` is the pre-compiled AUR package (avoids Go build dependency)
- No Docker/Podman CLI is installed (security: prevents container escape)
- No user is created — entrypoint handles this at runtime

- [ ] **Step 2: Test build**

Run: `docker build -t claude-sandbox:latest .`

Expected: Image builds successfully. Verify with `docker images | grep claude-sandbox`.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile with Arch Linux dev environment"
```

---

### Task 4: Create the wrapper script (`sandbox.sh`)

**Files:**
- Create: `sandbox.sh`

- [ ] **Step 1: Write the script**

```sh
#!/bin/sh
set -e

IMAGE_NAME="claude-sandbox:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
        distrobox-host-exec docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    else
        docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    fi
}

image_exists() {
    if [ -n "$CONTAINER_ID" ]; then
        distrobox-host-exec docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
    else
        docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
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
    DOCKER_CMD="docker run -it --rm $MOUNTS $ENV_VARS $IMAGE_NAME"

    if [ -n "$CONTAINER_ID" ]; then
        exec distrobox-host-exec $DOCKER_CMD
    else
        exec $DOCKER_CMD
    fi
}

# --- Main ---

case "${1:-}" in
    install) cmd_install ;;
    build)   cmd_build ;;
    *)       cmd_run ;;
esac
```

- [ ] **Step 2: Make executable**

Run: `chmod +x sandbox.sh`

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: add sandbox.sh wrapper script with distrobox-host-exec support"
```

---

### Task 5: Integration test — build and run

- [ ] **Step 1: Build the image**

Run: `./sandbox.sh build`

Expected: Image builds successfully without errors.

- [ ] **Step 2: Verify image contents**

Run: `docker run --rm claude-sandbox:latest sh -c "which node && which dotnet && which nvim && which tmux && which lazygit && which claude && which gosu"`

Expected: All paths printed, no errors.

- [ ] **Step 3: Verify entrypoint UID/GID mapping**

Run: `docker run --rm -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) claude-sandbox:latest id`

Expected: Output shows `uid=<your-uid>(sandbox) gid=<your-gid>(sandbox)`

- [ ] **Step 4: Verify no container runtime leaks**

Run: `docker run --rm claude-sandbox:latest sh -c "which docker; which podman; ls /var/run/docker.sock 2>&1"`

Expected: All commands fail / file not found.

- [ ] **Step 5: Run the full sandbox**

Run: `./sandbox.sh`

Expected: tmux session starts with nvim, claude, and lazygit windows. Verify:
- nvim opens with project files in `/workspace`
- claude starts with `--dangerously-skip-permissions`
- lazygit shows the repo
- Files created in `/workspace` appear on the host

- [ ] **Step 6: Commit any fixes**

If any issues were found and fixed in previous steps, commit them.

```bash
git add -A
git commit -m "fix: address issues found during integration testing"
```
