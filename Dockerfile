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

# Install gosu (direct binary download — AUR package no longer exists)
RUN curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-amd64" -o /usr/local/bin/gosu && \
    chmod +x /usr/local/bin/gosu && \
    gosu --version

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/ccode /usr/local/bin/ccode

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["ccode"]
