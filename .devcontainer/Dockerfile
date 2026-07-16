FROM ubuntu:24.04

ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Use bash with pipefail so failures in piped RUN commands (e.g. `curl … | bash`)
# propagate instead of being masked by the last command's exit status.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# GitHub CLI keyring fetched via ADD instead of curl; the apt install below
# references it. It is already dearmored, so no processing is needed.
ADD https://cli.github.com/packages/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg

# System packages: base tooling, the GitHub CLI, and the native libraries
# Crystal shards commonly link against (openssl, libxml2, libyaml, gmp,
# pcre2, libevent). Merged into a single layer; apt package lists are
# dropped after each apt step to keep the image small.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        git \
        gnupg \
        jq \
        libevent-dev \
        libgmp-dev \
        libpcre2-dev \
        libssl-dev \
        libxml2-dev \
        libyaml-dev \
        libz-dev \
        lsb-release \
        openssh-client \
        pkg-config \
        ripgrep \
        sudo \
        unzip \
        vim \
        wget \
        zip && \
    rm -rf /var/lib/apt/lists/* && \
    # GitHub CLI (gh); keyring added above
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/* && \
    # Crystal — official install script adds the openSUSE Build Service apt
    # repo and installs the latest stable `crystal` package (bundles shards).
    curl -fsSL https://crystal-lang.org/install.sh | bash && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Create user with matching UID/GID. Ubuntu 24.04 ships with a default
# `ubuntu` user at UID 1000, so we handle rename/renumber cases explicitly
# instead of assuming useradd will succeed.
RUN set -eux; \
    # 1. Handle the group for USER_GID
    if getent group "${USER_GID}" > /dev/null; then \
        # A group with this GID exists already; rename it to 'vscode' if needed
        existing_group="$(getent group "${USER_GID}" | cut -d: -f1)"; \
        if [ "${existing_group}" != "vscode" ]; then \
            groupmod -n vscode "${existing_group}"; \
        fi; \
    # No group with this GID yet; either rename existing 'vscode' group or create it
    elif getent group vscode > /dev/null; then \
        groupmod -g "${USER_GID}" vscode; \
    else \
        groupadd -g "${USER_GID}" vscode; \
    fi; \
    \
    # 2. Handle the user for USER_UID
    if getent passwd "${USER_UID}" > /dev/null; then \
        # A user with this UID exists; rename it to 'vscode' if needed
        existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
        if [ "${existing_user}" != "vscode" ]; then \
            usermod -l vscode "${existing_user}"; \
        fi; \
        # Ensure home dir is /home/vscode and move contents if necessary
        usermod -d /home/vscode -m vscode; \
        # Ensure primary group is our vscode group
        usermod -g "${USER_GID}" vscode; \
    # No user with this UID yet
    # 'vscode' exists but with a different UID; update it
    elif id -u vscode >/dev/null 2>&1; then \
        usermod -u "${USER_UID}" -g "${USER_GID}" -d /home/vscode -m vscode; \
    else \
        # Create new vscode user (-l: don't add a lastlog/faillog entry for the high UID)
        useradd -l -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" vscode; \
    fi; \
    \
    # 3. Sudoers
    echo 'vscode ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/vscode

USER vscode

# Claude Code CLI, installed to the user's home.
# $HOME/$PATH must stay literal so they expand at shell start, not build time.
# hadolint ignore=SC2016
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

ENV PATH=/home/vscode/.local/bin:$PATH
