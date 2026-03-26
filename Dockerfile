FROM archlinux:latest

# Update system and install packages
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
      nodejs npm \
      azure-cli icu \
      git base-devel \
      bash \
      jq wget openssh ripgrep wl-clipboard \
      && pacman -Scc --noconfirm

# Generate locales
RUN sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

# Create sandbox user (UID 1000 — remapped at runtime via --userns=keep-id)
RUN useradd -m -d /home/sandbox -s /bin/bash -u 1000 sandbox

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Pre-create XDG directories owned by sandbox so bind-mount intermediates
# don't end up root-owned
RUN mkdir -p /home/sandbox/.local/share \
             /home/sandbox/.local/state \
             /home/sandbox/.cache \
             /home/sandbox/.config \
             /home/sandbox/.gnupg && \
    touch /home/sandbox/.sandbox && \
    chown -R sandbox:sandbox /home/sandbox

USER sandbox

# Install .NET SDKs (default install-dir: ~/.dotnet)
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 8.0 && \
    /tmp/dotnet-install.sh --channel LTS --skip-non-versioned-files && \
    rm /tmp/dotnet-install.sh

# Install Claude Code (installs to ~/.local/bin/claude)
RUN curl -fsSL https://claude.ai/install.sh | bash

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
