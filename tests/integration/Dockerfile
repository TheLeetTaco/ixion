# Toolchain for the integration suite, so it runs anywhere Docker does.
#
# The suite needs a Linux userspace: it drives `claude` inside tmux and reads
# pane scrollback. That rules out running it natively on Windows, which is what
# this image exists to solve.
#
# run.sh's pre-flight demands tmux, claude, jq, bunx and cargo; the final RUN
# fails the build if any is missing, so a broken image never reaches a test run.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils \
      tmux jq \
      build-essential \
      procps less \
    && rm -rf /var/lib/apt/lists/*

# The harness launches claude with --permission-mode bypassPermissions, which
# Claude Code refuses to run as root ("cannot be used with root/sudo privileges
# for security reasons"). Under root the process exits instantly, taking its
# tmux session with it, and every capture-pane reports "no server running" —
# so the whole toolchain below installs into a normal user's home instead.
RUN useradd --create-home --shell /bin/bash ixion
USER ixion
ENV HOME=/home/ixion
WORKDIR /home/ixion

# bunx runs ajv-cli, which validates every session artifact the suite asserts on
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/ixion/.bun/bin:${PATH}"

# cargo builds and gates the Rust fixture in the chain case; clippy and rustfmt
# are the per-phase gates language-standards names, so the fixture can compose them
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal -c clippy -c rustfmt
ENV PATH="/home/ixion/.cargo/bin:${PATH}"

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/ixion/.local/bin:${PATH}"

# A fresh config means first-run onboarding: the TUI stops on the theme picker
# and never prints the "? for shortcuts" banner the harness waits for, so every
# case fails as "claude TUI did not start" while the process is alive and well.
# Marking onboarding done is what lets the suite reach a usable prompt.
RUN printf '%s\n' \
      '{' \
      '  "hasCompletedOnboarding": true,' \
      '  "theme": "dark",' \
      '  "numStartups": 1' \
      '}' > /home/ixion/.claude.json

WORKDIR /work

RUN for t in tmux jq bunx cargo claude; do \
      command -v "$t" >/dev/null 2>&1 || { echo "MISSING: $t"; exit 1; }; \
    done \
    && [ "$(id -u)" -ne 0 ] || { echo "image must not run as root"; exit 1; } \
    && tmux -V && jq --version && cargo --version && claude --version
