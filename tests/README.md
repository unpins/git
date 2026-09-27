# tests/

Runs Git's upstream end-to-end suite (`t/`, ~1000 shell scripts) against the
built binary. Not part of the build.

```bash
cd .. && nix build && cd tests
nix-shell shell.nix --run './run-tests.sh --quick'   # scripts-heavy subset, a few minutes
nix-shell shell.nix --run './run-tests.sh'           # everything
nix-shell shell.nix --run './run-tests.sh t7400-submodule-basic.sh'
```

`RESULT` picks another build (default `../result`), `WORK` the work directory
(default `/tmp/unpins-git-tests`), `JOBS` the parallelism.

## How it works

The upstream suite needs `t/helper/test-tool` and a configured source tree, so
the script unpacks the same source tarball the binary was built from and builds
it with the options the binary has (`NO_PERL`, `NO_PYTHON`, `NO_TCLTK`,
`NO_GETTEXT`), so the suite's prerequisites match what the binary can do. That
build only serves the test library; every `git` the tests run is ours, through
`GIT_TEST_INSTALLED`, laid out as `unpin install` does: the binary plus the
names it installs. Nothing else is staged: the exec path, the scripts and the
templates are the binary's own.

## Known failures

Full run, 2026-09-26, x86_64-linux: 31234 pass, 15 fail, 341 known
breakages (upstream's own `test_expect_failure`). The 15:

- **t0028 (3), t3434 (2):** musl's iconv writes ISO-2022-JP and UTF-16 byte
  sequences that differ from GNU libiconv's while decoding to the same text.
  nixpkgs already skips t0028 on musl.
- **t2082 (1), t7810 (2):** re-encoding on checkout and `grep` over a
  multibyte UTF-8 file. The same cases fail with the build from before the
  built-in shell, so they come from the libc, not from the scripts.
- **t2300 (5):** sources `git-sh-setup` from `$(git --exec-path)` in the
  test's own bash; that directory exists only inside the binary.
- **t0211 (2):** expects `git remote-http` to start a separate process; the
  helper runs inside the git process here.
