#!/usr/bin/env bash
#
# Rodar a suíte e2e upstream (`t/`) contra o nosso binário multicall+embed.
#
# Sub-shell: nix-shell ../tests/shell.nix --run './run-tests.sh ...'
#
# Forma:
#   ./run-tests.sh                # suíte completa, paralela
#   ./run-tests.sh --quick        # subset crítico (~9 tests, ~5 min)
#   ./run-tests.sh t1500-rev-parse.sh t7400-submodule-basic.sh
#
# Env:
#   RESULT      caminho para o build do flake (default ../result)
#   WORK        diretório de trabalho (default /tmp/unpins-git-tests)
#   JOBS        paralelismo (default nproc)
#   GIT_VERSION fixed em 2.51.2 (bate com o que nix-lib/nixos-25.11 traz)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$HERE")"
RESULT="${RESULT:-$PKG_DIR/result}"
WORK="${WORK:-${GIT_TESTS_WORKDIR:-/tmp/unpins-git-tests}}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
GIT_VERSION="${GIT_SRC_VERSION:-2.51.2}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

[ -e "$RESULT/bin/git" ] || { red "ERROR: $RESULT/bin/git not found. Run 'nix build' in $PKG_DIR first."; exit 1; }

# -- 1) Source tarball -------------------------------------------------------
# shell.nix expõe GIT_SRC_TARBALL pré-realizado. Se não estiver setado (script
# invocado fora do nix-shell), resolve via `nix eval`.
if [ -z "${GIT_SRC_TARBALL:-}" ]; then
  blue "==> Resolving git $GIT_VERSION source tarball (no shell.nix)..."
  command -v nix >/dev/null || { red "ERROR: GIT_SRC_TARBALL não setado e 'nix' não está em PATH. Use 'nix-shell shell.nix --run ...'."; exit 1; }
  GIT_SRC_TARBALL=$(nix eval --raw --impure --expr \
    "let p = (import (builtins.getFlake \"github:NixOS/nixpkgs/nixos-25.11\") { system = builtins.currentSystem; }).pkgsStatic.gitMinimal.src; in p.outPath")
  nix-store -r "$GIT_SRC_TARBALL" >/dev/null
fi
SRC_TARBALL="$GIT_SRC_TARBALL"

mkdir -p "$WORK"
SRC_DIR="$WORK/git-$GIT_VERSION"
if [ ! -f "$SRC_DIR/Makefile" ]; then
  blue "==> Unpacking source -> $SRC_DIR..."
  rm -rf "$SRC_DIR"
  tar -C "$WORK" -xf "$SRC_TARBALL"
fi

# -- 2) Build helpers (test-tool + .o files used by t/) ----------------------
# `make test-tool` requer libgit.a, então fazemos `make all` mesmo. Esse git
# nativo é descartável — só usado para compilar a infra de teste; os scripts
# da suíte usam GIT_TEST_INSTALLED para invocar nosso binário.
if [ ! -x "$SRC_DIR/t/helper/test-tool" ]; then
  blue "==> Building stock git + test helpers in $SRC_DIR (~3-5 min)..."
  # NO_GETTEXT pula libintl (não precisamos do gettext nativo só pra rodar tests);
  # DEVELOPER=1 trata warnings de modo estrito (pega regressões cedo).
  make -C "$SRC_DIR" -j"$JOBS" NO_GETTEXT=1 all >"$WORK/build.log" 2>&1 \
    || { red "Stock build failed. Tail of $WORK/build.log:"; tail -40 "$WORK/build.log"; exit 1; }
fi

# -- 3) Stage test tree -------------------------------------------------------
TREE="$WORK/test-tree"
blue "==> Staging test tree at $TREE..."
rm -rf "$TREE"
# -L: dereference any pre-existing symlinks (we make our own choice about
# hardlinks vs symlinks below). -a: preserve perms.
cp -aL "$RESULT" "$TREE"
chmod -R u+w "$TREE"

# 3a) Re-populate scripts removidos pelo postInstall do flake. Esses scripts
# moram embutidos no binário e são extraídos sob demanda em /tmp; aqui
# providamos as cópias originais para que os tests da suíte os encontrem
# diretamente em libexec. Em seguida (3b) reescrevemos o shebang para
# `#!<git> sh-shim`, replicando exatamente o que o extrator on-demand faz:
# o kernel exec o nosso binário, que dispara cmd_sh_shim -> dash_main. Sem
# essa reescrita, o /bin/sh do host (bash em distros) interpretaria os
# scripts e estaríamos testando uma combinação que não existe em produção.
blue "==> Restoring upstream scripts in libexec/git-core/..."
# Apontamos para as versões processadas (sem extensão) que o `make all` do
# stock build emitiu — `@SHELL_PATH@`, `@USE_GETTEXT_SCHEME@`,
# `@@GITPERLLIB@@`, etc. já foram substituídos. Os .sh/.perl/.py raw na
# raiz do source ainda têm placeholders e quebram t0201-gettext-fallbacks
# (`@USE_GETTEXT_SCHEME@` em vez de `fallthrough`), entre outros.
#
# Os processados de scripts perl/python que o stock build NÃO instala
# (git-svn, git-send-email — perl modules Git::SVN / Mail::* required) só
# existem porque rodamos `make all` no source. Providamos no test tree
# para que t91xx (svn) e t9001 (send-email) exerçam o fluxo real em vez
# de falhar todos por "is not a git command". GITPERLLIB do test-lib
# (set via GIT-BUILD-OPTIONS) já aponta para perl/build/lib/ no source.
declare -A SCRIPT_SRC=(
  [git-archimport]="$SRC_DIR/git-archimport"
  [git-cvsexportcommit]="$SRC_DIR/git-cvsexportcommit"
  [git-cvsimport]="$SRC_DIR/git-cvsimport"
  [git-cvsserver]="$SRC_DIR/git-cvsserver"
  [git-difftool--helper]="$SRC_DIR/git-difftool--helper"
  [git-filter-branch]="$SRC_DIR/git-filter-branch"
  [git-instaweb]="$SRC_DIR/git-instaweb"
  [git-merge-octopus]="$SRC_DIR/git-merge-octopus"
  [git-merge-one-file]="$SRC_DIR/git-merge-one-file"
  [git-merge-resolve]="$SRC_DIR/git-merge-resolve"
  [git-mergetool]="$SRC_DIR/git-mergetool"
  [git-mergetool--lib]="$SRC_DIR/git-mergetool--lib"
  [git-quiltimport]="$SRC_DIR/git-quiltimport"
  [git-request-pull]="$SRC_DIR/git-request-pull"
  [git-sh-i18n]="$SRC_DIR/git-sh-i18n"
  [git-sh-setup]="$SRC_DIR/git-sh-setup"
  [git-submodule]="$SRC_DIR/git-submodule"
  [git-web--browse]="$SRC_DIR/git-web--browse"
  [git-p4]="$SRC_DIR/git-p4"
  [git-gui--askpass]="$SRC_DIR/git-gui/git-gui--askpass"
  # git-subtree vive em contrib/ e não é built por `make all` (precisa
  # de `make -C contrib/subtree`). O arquivo .sh não tem placeholders
  # significativos, então o raw funciona.
  [git-subtree]="$SRC_DIR/contrib/subtree/git-subtree.sh"
  [git-svn]="$SRC_DIR/git-svn"
  [git-send-email]="$SRC_DIR/git-send-email"
)
for name in "${!SCRIPT_SRC[@]}"; do
  src="${SCRIPT_SRC[$name]}"
  if [ -f "$src" ]; then
    install -m 0755 "$src" "$TREE/libexec/git-core/$name"
  else
    echo "  warn: source for $name not found ($src)"
  fi
done

# mergetools/ (helpers chamados por git-mergetool--lib). Não recebem
# shebang reescrito — são `. sourced`, o kernel não lê a 1ª linha.
if [ -d "$SRC_DIR/mergetools" ]; then
  mkdir -p "$TREE/libexec/git-core/mergetools"
  cp -a "$SRC_DIR/mergetools/." "$TREE/libexec/git-core/mergetools/"
fi

# 3b) Reescrever o shebang dos scripts SHELL (mode 0755, source `.sh`) para
# `#!<canonical_git> sh-shim`. Isso garante que quando o kernel exec o
# script, ele exec o nosso git, que entra em cmd_sh_shim -> dash_main —
# exatamente o caminho dos scripts extraídos pelo embed em produção.
#
# NÃO mexer:
#   - scripts sourced (mode 0644 — git-sh-setup, git-sh-i18n,
#     git-mergetool--lib, mergetools/*): não passam pelo kernel exec, dash
#     ignora a 1ª linha quando carrega via `.`;
#   - scripts perl/python (source termina em .perl/.py — git-svn,
#     git-send-email, git-p4, git-archimport, ...): precisam dos
#     interpreters reais, não dash. No binário shipado esses são stubs
#     em shell (NO_PERL=1), por isso o extrator reescreve uniformly;
#     no test tree restauramos os scripts reais para exercer os caminhos
#     que dependem deles (t91xx, t9001, ...).
blue "==> Rewriting shell-script shebangs to '#!<git> sh-shim'..."
SOURCED_NAMES=(git-sh-setup git-sh-i18n git-mergetool--lib)
is_sourced() {
  local n="$1"
  for s in "${SOURCED_NAMES[@]}"; do [ "$n" = "$s" ] && return 0; done
  return 1
}
shebanged=0
skipped_interp=0
canonical_git="$TREE/bin/git"
[ -f "$canonical_git" ] || canonical_git="$TREE/bin/git.exe"
for name in "${!SCRIPT_SRC[@]}"; do
  dst="$TREE/libexec/git-core/$name"
  [ -f "$dst" ] || continue
  is_sourced "$name" && continue
  # Detecta interpreter pelo shebang real do arquivo de destino (mais robusto
  # que olhar a extensão do source — `make all` gera git-svn / git-send-email
  # sem extensão a partir de .perl).
  first_line=$(head -n 1 "$dst")
  case "$first_line" in
    *perl*|*python*|*wish*)
      skipped_interp=$((skipped_interp + 1))
      continue
      ;;
  esac
  # sed -i no Nix shell pode bater em store paths; usa tmpfile + mv.
  tmp="$dst.shebang-tmp"
  { printf '#!%s sh-shim\n' "$canonical_git"; tail -n +2 "$dst"; } > "$tmp"
  chmod 0755 "$tmp"
  mv "$tmp" "$dst"
  shebanged=$((shebanged + 1))
done
echo "  rewrote $shebanged shell shebangs; left $skipped_interp perl/python shebangs untouched"

# 3c) Converter symlinks→git em hardlinks (tests checam stat -c%h, e
# alguns assumem que o nome do helper aponta para o mesmo inode do binário
# canônico, não um symlink ao binário). `find -L` resolve.
blue "==> Converting helper symlinks -> hardlinks..."
canonical="$TREE/bin/git"
[ -f "$canonical" ] || canonical="$TREE/bin/git.exe"
converted=0
while IFS= read -r link; do
  target=$(readlink -f "$link" 2>/dev/null || true)
  if [ "$target" = "$canonical" ] || [ "$target" = "$(readlink -f "$canonical")" ]; then
    rm -f "$link"
    ln "$canonical" "$link"
    converted=$((converted + 1))
  fi
done < <(find "$TREE" -type l)
echo "  converted $converted symlinks to hardlinks (canonical: $canonical)"

# -- 4) Run suite -------------------------------------------------------------
export GIT_TEST_INSTALLED="$TREE/bin"
export GIT_EXEC_PATH="$TREE/libexec/git-core"
# test-lib.sh:1397 sobrescreve GIT_EXEC_PATH com o exec-path compile-time do
# binário (no /nix/store, sem os scripts que restauramos). O override
# GIT_TEST_EXEC_PATH (1400) tem precedência — apontamos para o test tree
# para que `git difftool` e amigos achem os helpers shell que repopulamos.
export GIT_TEST_EXEC_PATH="$TREE/libexec/git-core"
# Garantir que perl/python encontrados pelos tests são os nossos (do shell).
unset PERL5LIB || true

QUICK_TESTS=(
  t0000-basic.sh
  t0001-init.sh
  t1000-read-tree-m-3way.sh
  t1500-rev-parse.sh
  t3000-ls-files-others.sh
  t5500-fetch-pack.sh
  t5601-clone.sh
  t7400-submodule-basic.sh
  t7800-difftool.sh
)

cd "$SRC_DIR/t"

blue "==> Running test suite"
echo "    GIT_TEST_INSTALLED=$GIT_TEST_INSTALLED"
echo "    GIT_EXEC_PATH=$GIT_EXEC_PATH"
echo "    JOBS=$JOBS"
echo ""

# `prove` é o runner que o Makefile usa quando há paralelismo + agregação
# bonita. Cai pra `make` puro se prove não existir.
mode="${1:-}"
case "$mode" in
  --quick)
    blue "    mode: --quick (${#QUICK_TESTS[@]} tests)"
    set +e
    make -j"$JOBS" "${QUICK_TESTS[@]}"
    rc=$?
    set -e
    ;;
  --all|"")
    blue "    mode: full suite"
    set +e
    # -k: keep going on failure (without this, make stops on the first
    # failed tXXXX.sh and 95%+ of the suite never runs).
    make -j"$JOBS" -k
    rc=$?
    set -e
    ;;
  *)
    blue "    mode: explicit tests ($*)"
    set +e
    make -j"$JOBS" "$@"
    rc=$?
    set -e
    ;;
esac

echo ""
if [ "$rc" -eq 0 ]; then
  green "==> All tests passed."
else
  red   "==> Suite finished with rc=$rc. See per-test logs under $SRC_DIR/t/test-results/."
fi
exit "$rc"
