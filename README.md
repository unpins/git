# git

Standalone build of [Git](https://git-scm.com/). Runs on any Linux or macOS without external dependencies.

Linux/Darwin only — Windows is blocked by upstream nixpkgs `pkgsCross.mingwW64` breakage (gawk, bash, libev, ngtcp2 all fail to cross-compile). A future port via Cosmopolitan + this same embedded-dash architecture is feasible.

This package is a **single 15 MB binary** that contains:

- All of Git's own C built-ins (`status`, `commit`, `log`, `diff`, …)
- 11 dashed-helper C programs folded as multicall (`git-daemon`, `git-http-backend`, `git-shell`, `scalar`, `git-remote-https/http/ftp/ftps`, `git-http-fetch`, `git-imap-send`, `git-http-push`, `git-sh-i18n--envsubst`)
- A statically linked `dash` (POSIX `/bin/sh` clone) exposed as the internal `git sh-shim` subcommand
- The 19 POSIX shell-script subcommands (`git-filter-branch`, `git-submodule`, `git-mergetool`, `git-merge-octopus`, `git-merge-resolve`, `git-merge-one-file`, `git-difftool--helper`, `git-request-pull`, `git-quiltimport`, `git-web--browse`, `git-subtree`, …) plus their sourced helpers (`git-sh-setup`, `git-sh-i18n`, `git-mergetool--lib`) and 24 `mergetools/*` configs, embedded as byte arrays inside the binary

When the user runs e.g. `git filter-branch ...`, the binary `mkdtemp("/tmp/unpins-git.XXXXXX")`s a fresh dir, extracts only the requested script and its transitive `. source` deps (computed at build time), rewrites the script's shebang to `#!<self> sh-shim`, then `fork`+`exec`s it. The shebanged child re-enters this binary; the `sh-shim` built-in invokes the linked `dash_main` on the script. Any `git foo` invoked from inside the script just hits the same binary again via PATH. The tmp dir is `rmrf`'d when the command returns, with `atexit` + signal handlers as cleanup safety nets.

Pure-C commands (`git status`, `git commit`, `git log`, `git diff`, …) never touch the filesystem for embed purposes — extraction cost is paid only for the ~19 shell-script subcommands.

Total install: ~16 MB vs ~80 MB for separate binaries with a separate shell.

Out of scope: `git-cvsserver` (Perl) and the Tcl/Tk parts (`git-citool`, `git-gui`); these would need Perl/wish on the host.

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
