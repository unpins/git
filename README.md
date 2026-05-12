# git

Standalone build of [Git](https://git-scm.com/). Runs on any Linux or macOS without external dependencies.

Linux/Darwin only — Windows is blocked by upstream nixpkgs `pkgsCross.mingwW64` breakage (gawk, bash, libev, ngtcp2 all fail to cross-compile). Even bypassing nixpkgs's git package with a from-scratch derivation, getting HTTPS working requires the full static curl/openssl/libidn2 chain, several layers deep. Tracked but not pursued.

This package is a **multicall binary**: `git`, `git-remote-https`, `git-shell`, `git-daemon`, `scalar`, and 8 other helpers all share one 15 MB binary instead of 15 separate copies (each ~10–14 MB statically linked). Total install: ~18 MB vs ~80 MB for separate binaries.

## Installation

You can install this package instantly using the [unpin](https://github.com/unpins/unpin) package manager:

```bash
unpin git
```

Or run it without installing:

```bash
unpin run git
```

## Build locally

```bash
nix build github:unpins/git
./result/bin/git
```

Or, in one shot:

```bash
nix run github:unpins/git
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual Download

Standalone binaries and data packages are available on the [Releases](https://github.com/unpins/git/releases) page.
