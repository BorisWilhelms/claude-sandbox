# claude-sandbox

A containerized sandbox for running [Claude Code](https://code.claude.com) with `--dangerously-skip-permissions`. Isolates Claude from the host filesystem while forwarding SSH, GPG, and clipboard access.

## Requirements

- **Podman** (Linux) or **Docker** (macOS)
- Arch Linux x86_64 host, or macOS with Apple Silicon (runs via Rosetta)

## Quick start

```sh
git clone https://github.com/BorisWilhelms/claude-sandbox.git
cd claude-sandbox
./sandbox.sh install
claude-sandbox build
```

Then from any project directory:

```sh
claude-sandbox        # run Claude Code in the sandbox
claude-sandbox shell  # drop into a bash shell in the container
claude-sandbox build  # rebuild the image
```

## How it works

`sandbox.sh` builds an Arch Linux container image with development tools and Claude Code, then runs it with bind-mounts for the current working directory and explicitly configured host paths. The working directory is mounted at its real path so Claude Code's project memory works correctly.

### Container contents

- Node.js, npm
- .NET SDK 8.0 + LTS (installed via official script)
- Azure CLI
- git, jq, wget, openssh, ripgrep
- Claude Code (native installer)

### What gets mounted

The current working directory is always mounted read-write. Additional mounts are configured in `~/.config/claude-sandbox/sandbox.conf`:

```
# Format: host_path [container_path] [rw]
# Default mode is ro (read-only). Append "rw" for read-write.
# ~ is expanded to $HOME. If container_path is omitted, it mirrors
# the host path under /home/sandbox/.

~/.config/git
~/.claude rw
~/.claude.json rw
~/.bashrc
~/.config/bash
~/.local/share/azure
~/.ssh/known_hosts
```

Additionally, `sandbox.sh` automatically forwards:

- **SSH agent** (`$SSH_AUTH_SOCK`)
- **GPG agent** (extra socket)
- **Wayland socket** (clipboard access for image paste)

### What is NOT accessible

- Home directory (except explicitly mounted paths)
- Other projects / filesystem
- Host localhost / network services (no `--network=host`)
- API keys from environment variables

## Security hooks

The installer sets up [Claude Code hooks](https://code.claude.com/docs/en/hooks) that enforce sandbox policies. These only activate when `~/.sandbox` exists (inside the container).

### sandbox-guard.sh (PreToolUse on Bash)

| Rule | Description |
|------|-------------|
| No force-push | Blocks `git push --force`, `--force-with-lease` |
| No hard reset | Blocks `git reset --hard` |
| No git clean | Blocks `git clean -f` |
| No branch -D | Blocks `git branch -D` (use `-d` instead) |
| No broad rm | Blocks `rm -rf /`, `rm -rf ~`, `rm -rf .` |
| az allowlist | Only `az monitor`, `devops`, `boards`, `repos`, `pipelines`, `vm show` |
| Hook protection | Blocks shell access to `.claude/hooks/` and `.claude/settings*` |

### sandbox-protect-hooks.sh (PreToolUse on Edit/Write)

Blocks Edit/Write operations targeting `~/.claude/hooks/`, `~/.claude/settings.json`, and `~/.claude/settings.local.json`. Prevents Claude from disabling its own guardrails.

## Configuration

### Hook registration

If you already have a `~/.claude/settings.json`, the installer prints the JSON snippet to add manually. For a fresh install, it creates the settings file automatically.

The hooks need to be registered in `hooks.PreToolUse`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/sandbox-guard.sh"
        }]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/sandbox-protect-hooks.sh"
        }]
      }
    ]
  }
}
```

### Customizing the az allowlist

Edit `~/.claude/hooks/sandbox-guard.sh` and modify the grep pattern:

```bash
if ! echo "$COMMAND" | grep -qE 'az\s+(monitor|devops|boards|repos|pipelines|vm\s+show)'; then
```

### Adding mounts

Edit `~/.config/claude-sandbox/sandbox.conf`. Lines starting with `#` are comments. Each line is:

```
host_path [container_path] [rw]
```

If `container_path` is omitted, the host path is mirrored under `/home/sandbox/`.

## Platform support

| Platform | Runtime | Notes |
|----------|---------|-------|
| Linux x86_64 | Podman | Primary target. Uses `--userns=keep-id` for UID mapping. |
| macOS x86_64 | Docker | Works natively. |
| macOS ARM (M1/M2/M3) | Docker | Runs via Rosetta (`--platform linux/amd64`). |
| Linux (distrobox) | Podman | Supported. Commands proxied via `distrobox-host-exec`. |

## File layout

```
# CLI entrypoint (macOS with Homebrew: /opt/homebrew/bin/claude-sandbox)
~/.local/bin/claude-sandbox

~/.local/share/claude-sandbox/       # Dockerfile, scripts (copied on install)
~/.config/claude-sandbox/sandbox.conf # Mount configuration
~/.claude/hooks/sandbox-guard.sh     # Security hook (Bash commands)
~/.claude/hooks/sandbox-protect-hooks.sh  # Security hook (Edit/Write)
```

## Known limitations

- No outbound network restrictions. Claude can reach any host.
- SSH agent is fully forwarded. Claude can push to any remote your key has access to.
- GPG agent is forwarded. Claude can sign commits.
- Wayland socket grants clipboard and input access to the host desktop.
- On ARM Macs, the container runs under Rosetta emulation (slower than native).
