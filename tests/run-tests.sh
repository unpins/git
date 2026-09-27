#!/usr/bin/env bash
#
# Run git's upstream `t/` suite against the built binary.
#
#   nix-shell shell.nix --run './run-tests.sh --quick'
#   nix-shell shell.nix --run './run-tests.sh'                   # everything
#   nix-shell shell.nix --run './run-tests.sh t7400-submodule-basic.sh'
#
# Env: RESULT (default ../result), WORK (default /tmp/unpins-git-tests),
#      JOBS (default nproc).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULT="${RESULT:-$(dirname "$HERE")/result}"
WORK="${WORK:-/tmp/unpins-git-tests}"
JOBS="${JOBS:-$(nproc)}"
: "${GIT_SRC_TARBALL:?run inside nix-shell shell.nix}"

[ -x "$RESULT/bin/git" ] || { echo "no $RESULT/bin/git; run nix build first" >&2; exit 1; }

# The stock tree only provides test-tool and the test library. It is built
# with the options the shipped binary has, so the suite's prerequisites
# (PERL, PYTHON, GETTEXT, ...) match what the binary can actually do.
SRC="$WORK/git-$GIT_SRC_VERSION"
OPTS=(NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1)
if [ ! -x "$SRC/t/helper/test-tool" ]; then
  mkdir -p "$WORK"
  rm -rf "$SRC"
  tar -C "$WORK" -xf "$GIT_SRC_TARBALL"
  echo "==> building test-tool in $SRC"
  make -C "$SRC" -j"$JOBS" "${OPTS[@]}" all >"$WORK/build.log" 2>&1 \
    || { tail -40 "$WORK/build.log"; exit 1; }
fi

# What `unpin install git` lays out: the binary, plus the names it answers
# to. Nothing else: the exec path, scripts and templates are the binary's own.
BIN="$WORK/bin"
rm -rf "$BIN"
mkdir -p "$BIN"
cp "$RESULT/bin/git" "$BIN/git"
chmod u+w "$BIN/git"
for a in git-receive-pack git-upload-pack git-upload-archive git-shell \
         git-http-backend scalar; do
  ln "$BIN/git" "$BIN/$a"
done

if [ "${1:-}" = "--quick" ]; then
  set -- t0001-init.sh t1500-rev-parse.sh t3903-stash.sh t5150-request-pull.sh \
         t6060-merge-index.sh t7003-filter-branch.sh t7400-submodule-basic.sh \
         t7406-submodule-update.sh t7610-mergetool.sh t7800-difftool.sh
fi

export GIT_TEST_INSTALLED="$BIN"
cd "$SRC/t"
rm -rf test-results
if [ $# -gt 0 ]; then
  make -j"$JOBS" "${OPTS[@]}" -k "$@" || true
else
  make -j"$JOBS" "${OPTS[@]}" -k || true
fi
make "${OPTS[@]}" aggregate-results
