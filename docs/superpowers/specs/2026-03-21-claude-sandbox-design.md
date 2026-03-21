# Claude Code Sandbox — Design Spec

## Goal

Provide a containerized sandbox for running Claude Code with `--dangerously-skip-permissions`, isolating it from the host filesystem while keeping the developer workflow intact. Must work for colleagues using Docker directly and for Boris using distrobox (via `distrobox-host-exec`).

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

### 2. Bind-Mounts (Docker mode)

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

**Additional environment variables for GPG (Docker mode only, if GPG socket mounted):**
- `GPG_AGENT_INFO=/home/sandbox/.gnupg/S.gpg-agent`

The `entrypoint.sh` creates `/home/sandbox/.gnupg/` before the socket mount becomes accessible.

**Note on distrobox mode:** When using distrobox (option 2 in runtime detection) **without** `--home`, distrobox mounts the host home directory automatically and maps the host user. All configs (nvim, tmux, git, claude, GPG, SSH) are available via the shared home — the bind-mount table above does **not** apply. Only the project directory mount to `/workspace` is explicitly added. With `--home /home/sandbox`, distrobox does **not** auto-mount the host home, so the Docker-mode bind-mounts would be needed.

**Recommendation:** Use distrobox **without** `--home` so that the host home is shared and no explicit config mounts are needed. The tradeoff is less isolation (distrobox can see all of `$HOME`), but this matches Boris's current distrobox workflow.

### 3. `sandbox.sh` / `claude-sandbox`

A single wrapper script with the following commands:

```
claude-sandbox              # build image if needed, start container, run ccode
claude-sandbox install      # copy script to ~/.local/bin/claude-sandbox
claude-sandbox build        # explicitly (re)build the image
```

**Runtime detection logic (in order):**

1. **Inside a distrobox?** (`CONTAINER_ID` env var is set)
   - Use `distrobox-host-exec docker run ...` to execute Docker on the host
   - All host paths are resolved before passing to `distrobox-host-exec`
2. **distrobox available on host?**
   - Use `distrobox create --image claude-sandbox:latest --name claude-sandbox` (no `--home` — host home is shared)
   - Then `distrobox enter claude-sandbox -- bash -c 'cd /workspace && ccode'`
   - Distrobox handles user mapping and home mounts automatically
   - Container is **persistent** (survives restarts, `distrobox rm` to remove)
3. **Docker available?**
   - Use `docker run -it --rm` with bind-mounts from section 2
   - Container is **ephemeral** (removed after exit)

**Start sequence:**

1. Check if image `claude-sandbox:latest` exists, build if not
2. Collect mounts — SSH agent socket only if `$SSH_AUTH_SOCK` is set, GPG agent socket only if `gpgconf --list-dirs agent-extra-socket` returns a valid path
3. Start container interactively with all mounts and env vars
4. Container runs entrypoint → creates user → runs `ccode` (tmux session)

### 4. User/Permission Mapping

- **Docker:** The `entrypoint.sh` script creates user `sandbox` with UID/GID matching `HOST_UID`/`HOST_GID` at container start. This ensures bind-mounted files have correct ownership. Uses `gosu` (installed in Dockerfile) to drop privileges.
- **Distrobox:** Handles user mapping natively — host user is replicated inside the container.

### 5. Out of Scope (v1)

- Network isolation / firewall rules
- Multi-architecture image builds
- CI/CD integration
- Automatic image updates
- `.dockerignore` (build context is minimal — only Dockerfile and scripts)
- Reproducible builds / pinned image tags
