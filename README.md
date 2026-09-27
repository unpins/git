# git

[Git](https://git-scm.com/), the distributed version control system. A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/git/actions/workflows/git.yml/badge.svg)](https://github.com/unpins/git/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

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

This installs `git` together with the other commands Git itself installs:
`scalar` and the server-side `git-receive-pack`, `git-upload-pack`,
`git-upload-archive`, `git-shell` and `git-http-backend`.

Commands that are shell scripts upstream (`git submodule`, `git filter-branch`,
`git mergetool`, `git difftool`, `git subtree`, `git request-pull`, …) work
with nothing else installed, on Windows too: the binary carries the shell and
the tools (`sed`, `grep`, `awk`, …) they run with.

## Man pages

The Git manual is embedded, so `unpin man git` and `unpin man git git-rebase`
work offline.

## Build locally

```bash
nix build github:unpins/git
./result/bin/git --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/git/releases) page has standalone binaries for manual download.

## Build notes

- **One shell everywhere.** Git's scripts, the commands it runs through a shell
  (`!` aliases, `core.editor` and the like) and user filters such as
  `filter-branch --tree-filter` all run in the same built-in shell,
  [busybox-w32](https://frippery.org/busybox/)'s `ash`, with its `sed`, `grep`,
  `awk` and friends, on every platform. Hooks keep their `#!` line: on Linux and
  macOS a `#!/bin/sh` hook runs with the system's `/bin/sh`; on Windows, where
  there is none, with the built-in one.
- **Any file name on Windows.** `git.exe` runs with UTF-8 as its code page, so
  the shell and its tools handle names in any script, not only those of the
  system's language. This needs Windows 10 version 1903 or later; on older
  versions they are limited to the system's code page.
- **`git --exec-path` names a directory inside the binary.** Git and its own
  scripts use it as usual, but a shell outside Git cannot read from it:
  `. "$(git --exec-path)/git-sh-setup"` in your own script does not work.
- **Not included:** `gitk`, `git gui` and `git citool` (Tcl/Tk);
  `git send-email`, `git svn`, `git cvsserver`, `git cvsimport`,
  `git cvsexportcommit`, `git archimport` and `git instaweb` (Perl); `git p4`
  (Python). These print that they are not available.
- **`git maintenance start`** schedules this binary itself. On Windows that is
  `git.exe` rather than upstream's windowless `headless-git.exe`, which is not
  included.
- **Tests:** the upstream end-to-end suite runs from `tests/`, against the built
  binary; see that directory's README.
