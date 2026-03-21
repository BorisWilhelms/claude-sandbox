FROM archlinux:latest

# Update system and install packages
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
      nodejs npm \
      dotnet-sdk \
      azure-cli \
      git base-devel \
      bash \
      neovim tmux lazygit \
      && pacman -Scc --noconfirm

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Create sandbox user (UID 1000 — remapped at runtime via --userns=keep-id)
RUN useradd -m -d /home/sandbox -s /bin/bash -u 1000 sandbox

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/ccode /usr/local/bin/ccode

USER sandbox
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["ccode"]
