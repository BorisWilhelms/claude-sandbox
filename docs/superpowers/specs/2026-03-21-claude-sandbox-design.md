# Claude Code Sandbox — Design Spec

## Goal

Provide a containerized sandbox for running Claude Code with `--dangerously-skip-permissions`, isolating it from the host filesystem while keeping the developer workflow intact. Uses Docker (or Podman) as the container runtime. Must also work when invoked from inside a distrobox (via `distrobox-host-exec`).

## Primary Protection Target

Host filesystem isolation — Claude can only access the mounted project directory and explicitly shared configs. Network restrictions are nice-to-have, not in scope for v1.

## Components

### 1. Dockerfile

**Base image:** `archlinux:latest` (rolling release — builds are not reproducible across time, accepted tradeoff for v1)

**Packages:**
- `nodejs`, `npm`
- `dotnet-sdk`
- `azure-cli`
- `git`, `base-devel`
- `neovim`, `tmux`, `lazygit`
- `gosu` (AUR — for privilege dropping in entrypoint)

**Post-install:**
- `npm install -g @anthropic-ai/claude-code`
- Working directory set to `/workspace`
- No extra capabilities or `--privileged` — minimal permissions only

**No user created in the Dockerfile.** User mapping is handled at runtime (see section 4).

**Entrypoint:** An `entrypoint.sh` script that:
1. Creates a `sandbox` user with the UID/GID passed via environment variables (`HOST_UID`, `HOST_GID`)
2. Sets the home directory to `/home/sandbox`
3. Execs into the `ccode` script as that user (via `exec gosu sandbox ...` or `exec su-exec sandbox ...`)

**`ccode` script** (copied into image at `/usr/local/bin/ccode`):
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

### 2. Bind-Mounts

All container-side paths use the explicit home `/home/sandbox`.

| Host | Container | Mode | Purpose |
|---|---|---|---|
| `$(pwd)` | `/workspace` | rw | Project files |
| `~/.claude/` | `/home/sandbox/.claude/` | rw | Credentials + settings (persistent) |
| `~/.gitconfig` | `/home/sandbox/.gitconfig` | ro | Git identity + signing config |
| `~/.config/nvim/` | `/home/sandbox/.config/nvim/` | ro | Neovim configuration |
| `~/.tmux.conf` | `/home/sandbox/.tmux.conf` | ro | Tmux configuration |
| `~/.local/share/nvim/` | `/home/sandbox/.local/share/nvim/` | rw | Neovim plugins/state (persistent) |
| `$SSH_AUTH_SOCK` | `/tmp/ssh-agent.sock` | socket | SSH agent forwarding |
| `$(gpgconf --list-dirs agent-extra-socket)` | `/home/sandbox/.gnupg/S.gpg-agent` | socket | GPG signing (only if socket exists) |

**Environment variables forwarded:**
- `ANTHROPIC_API_KEY` (if set on host)
- `SSH_AUTH_SOCK=/tmp/ssh-agent.sock` (remapped inside container)
- `HOST_UID=$(id -u)` / `HOST_GID=$(id -g)` (for entrypoint user creation)

**Additional environment variables (if GPG socket mounted):**
- `GPG_AGENT_INFO=/home/sandbox/.gnupg/S.gpg-agent`

The `entrypoint.sh` creates `/home/sandbox/.gnupg/` before the socket mount becomes accessible.

**Security: no container runtime socket is mounted.** Docker/Podman sockets are never bind-mounted into the sandbox. Docker and Podman CLIs are not installed in the image. This prevents container escape via `docker run -v /:/host`.

### 3. `sandbox.sh` / `claude-sandbox`

A single wrapper script with the following commands:

```
claude-sandbox              # build image if needed, start container, run ccode
claude-sandbox install      # copy script to ~/.local/bin/claude-sandbox
claude-sandbox build        # explicitly (re)build the image
```

**Runtime detection logic:**

1. **Inside a distrobox?** (`CONTAINER_ID` env var is set)
   - Use `distrobox-host-exec docker run ...` to execute Docker on the host
   - All host paths are resolved before passing to `distrobox-host-exec`
2. **Otherwise:** Use `docker run -it --rm` directly

Container is always **ephemeral** (`--rm` — removed after exit).

**Start sequence:**

1. Check if image `claude-sandbox:latest` exists, build if not
2. Collect mounts — SSH agent socket only if `$SSH_AUTH_SOCK` is set, GPG agent socket only if `gpgconf --list-dirs agent-extra-socket` returns a valid path
3. Start container interactively with all mounts and env vars
4. Container runs entrypoint → creates user → runs `ccode` (tmux session)

### 4. User/Permission Mapping

The `entrypoint.sh` script creates user `sandbox` with UID/GID matching `HOST_UID`/`HOST_GID` at container start. This ensures bind-mounted files have correct ownership. Uses `gosu` (installed in Dockerfile) to drop privileges.

### 5. Out of Scope (v1)

- Network isolation / firewall rules
- Multi-architecture image builds
- CI/CD integration
- Automatic image updates
- `.dockerignore` (build context is minimal — only Dockerfile and scripts)
- Reproducible builds / pinned image tags
