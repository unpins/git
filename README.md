# git

[Git](https://git-scm.com/) as a single self-contained binary, built natively for Linux and macOS.

[![CI](https://github.com/unpins/git/actions/workflows/git.yml/badge.svg)](https://github.com/unpins/git/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install git`.

## Usage

Run it with [unpin](https://github.com/unpins/unpin):

```bash
unpin git status
unpin git clone https://github.com/git/git
```

To install it onto your PATH:

```bash
unpin install git
```

## Build locally

```bash
nix build github:unpins/git
./result/bin/git --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/git/releases) page has standalone binaries, plus a data archive with Git's `share` files — the templates `git init` copies into a new repository, and the shell completions.

## Build notes

- **The shell subcommands work with no shell on the host.** `git submodule`,
  `git filter-branch`, `git mergetool`, `git subtree` and the rest are POSIX
  shell scripts upstream; they and a `dash` to run them are carried inside the
  binary, and Git extracts what a command needs on the spot.
- **`git init` templates** are not inside the binary; they come from the
  release's data archive.
- **Not shipped:** `git gui`, `gitk` and `git citool` (Tcl/Tk), and
  `git cvsserver` (Perl) — each needs an interpreter on the host.
- **No man pages:** this build ships none, so `git help <command>` falls back to
  whatever `man` finds on the host. `git <command> -h` always prints the usage.
- **Only `git` lands on `PATH`.** The server-side helpers (`git-http-backend`,
  `git-receive-pack`, `git-shell`, `git-upload-archive`, `git-upload-pack`) and
  `scalar` are inside the binary but are not announced to `unpin` yet, so
  installing does not create commands for them.
- **Windows** is built (a PE that imports nothing but Windows' own DLLs) but has
  not been exercised on Windows itself, so it is not claimed above.
- **Tests:** the upstream end-to-end suite runs from `tests/`, not from the
  build; see that directory's README for the current pass rate.
