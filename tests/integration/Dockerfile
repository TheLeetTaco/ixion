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

# bunx runs ajv-cli, which validates every session artifact the suite asserts on
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# cargo builds and gates the Rust fixture in the chain case; clippy and rustfmt
# are the per-phase gates language-standards names, so the fixture can compose them
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal -c clippy -c rustfmt
ENV PATH="/root/.cargo/bin:${PATH}"

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /work

RUN for t in tmux jq bunx cargo claude; do \
      command -v "$t" >/dev/null 2>&1 || { echo "MISSING: $t"; exit 1; }; \
    done \
    && tmux -V && jq --version && cargo --version && claude --version
