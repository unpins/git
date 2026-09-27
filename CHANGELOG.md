# Changelog

## [Unreleased]

### Added

- First release of Git 2.54.0 as a single self-contained binary for Linux,
  macOS and Windows, on x86_64 and arm64 (plus i686, armv7l, ppc64le and
  riscv64 on Linux).

  The commands Git writes in shell work with nothing else installed:
  `git submodule`, `git filter-branch`, `git mergetool`, `git difftool`,
  `git subtree`, `git request-pull` and the rest run in a shell carried inside
  the binary, with the `sed`, `grep` and `awk` they need, on Windows as well as
  Linux and macOS. `git init` sets up the usual sample hooks, the Git manual is
  embedded for `unpin man git`, and `unpin install git` also installs `scalar`
  and the server-side commands (`git-upload-pack`, `git-receive-pack`,
  `git-upload-archive`, `git-shell`, `git-http-backend`).
