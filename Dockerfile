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
