# CI Baseline Template

The concrete form of the **CI Baseline** section in `language-standards`. Fold in the items a project's CI lacks; leave out anything the user declined. Every action is pinned to a commit with its tag as a comment, and the bot config covers `github-actions` so those pins get refreshed.

## `.github/workflows/ci.yml`

Keep the `deny` job only when `deny.toml` declares an `[advisories]` table — the same condition as the **Advisory gate**. It does not build, so it carries no cache.

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  fmt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: dtolnay/rust-toolchain@7e38f4b43b4db5c8dd498af069a4f6196df1d067 # master
        with:
          toolchain: stable
          components: rustfmt
      - run: cargo fmt --check

  clippy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: dtolnay/rust-toolchain@7e38f4b43b4db5c8dd498af069a4f6196df1d067 # master
        with:
          toolchain: stable
          components: clippy
      - uses: Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6 # v2.9.2
      - run: cargo clippy --all-targets --locked -- -D warnings

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: dtolnay/rust-toolchain@7e38f4b43b4db5c8dd498af069a4f6196df1d067 # master
        with:
          toolchain: stable
          components: llvm-tools-preview
      - uses: Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6 # v2.9.2
      - uses: taiki-e/install-action@183e4297cca2404691e9380e1307288dced5c82a # v2.87.25
        with:
          tool: cargo-llvm-cov
      - run: cargo llvm-cov --locked --fail-under-lines 80
      - run: cargo test --doc --locked

  deny:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: EmbarkStudios/cargo-deny-action@3c6349835b2b7b196a839186cb8b78e02f7b5f25 # v2.1.1
```

`cargo llvm-cov` is the test step — running `cargo test` beside it would build and run the suite twice — and it skips doc-tests, which the last step covers.

## `.github/workflows/audit.yml`

A schedule surfaces advisories published against code nobody has touched. `rustsec/audit-check` opens an issue per advisory and reports a check, hence the two write permissions.

```yaml
name: Security audit
on:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:

permissions:
  contents: read
  issues: write
  checks: write

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: rustsec/audit-check@69366f33c96575abad1ee0dba8212993eecbe998 # v2.0.0
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
```

## Dependency bot

One of the two. Both hold an update until the release is 14 days old; Dependabot exempts security updates from the cooldown.

`renovate.json` — the `github-actions` manager is on by default:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "minimumReleaseAge": "14 days"
}
```

`.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: cargo
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 14
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 14
```
