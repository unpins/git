# playground/git/tests/

Roda a suíte e2e upstream (`t/`, ~1000 scripts shell) contra o nosso binário
multicall+embed. Não faz parte do build — é um harness à parte.

## Pré-requisitos

- Build do flake já feito (`cd .. && nix build`). Confere `../result/bin/git`.
- Nix com `flakes` + `nix-command` habilitados (já é o caso desse repo).

## Uso

```bash
nix-shell shell.nix --run './run-tests.sh --quick'   # subset crítico (~5 min)
nix-shell shell.nix --run './run-tests.sh'           # suíte completa (~20-30 min)
nix-shell shell.nix --run './run-tests.sh t1500-rev-parse.sh'   # ad-hoc
```

Variáveis úteis:

- `RESULT=/caminho/result` — usa outro build (default `../result`).
- `WORK=/tmp/foo` — workdir alternativo (cache do source + build descartável).
- `JOBS=N` — paralelismo (default `nproc`).

## Como funciona

1. **Resolve o source** via `nix eval` em `pkgsStatic.gitMinimal.src` (mesmo
   tarball que o flake usa, 2.51.2) e descompacta em `$WORK/git-2.51.2/`.
2. **Builda stock git + `test-tool`** no source descompactado. Esse binário é
   **descartado** — só serve para gerar `t/helper/test-tool` e o que mais a
   infra de teste precisar.
3. **Monta o test tree** em `$WORK/test-tree/` copiando `result/` e
   contornando as 3 limitações do nosso build:
   - **Scripts removidos do libexec** (`git-submodule`, `git-mergetool`,
     `git-difftool--helper`, …): reinstala as cópias originais do source
     tree no `libexec/git-core/`. **Reescreve o shebang** dos scripts
     executáveis (mode 0755) para `#!<tree>/bin/git sh-shim`, idêntico
     ao que o extrator on-demand do binário faz em runtime. Resultado:
     o kernel exec o nosso git, que entra em `cmd_sh_shim` →
     `dash_main`. Os scripts no test tree rodam sob o **dash embutido**
     no binário, não sob o `/bin/sh` do host. Scripts `.`-sourced
     (mode 0644: `git-sh-setup`, `git-sh-i18n`, `git-mergetool--lib`,
     `mergetools/*`) ficam com a 1ª linha original — o kernel não lê
     shebang em `.` source.
   - **Symlinks → hardlinks**: o `postInstall` do flake colapsa duplicatas
     em symlinks (economia de bytes). Alguns tests checam link count via
     `stat -c%h`; reconvertendo para hardlinks (mesmo inode do binário
     canônico) satisfazemos os asserts.
   - **`/bin/sh` interno (dash)**: coberto pela reescrita de shebang
     acima. Validação empírica: `head -1 $tree/libexec/git-core/git-submodule`
     deve mostrar `#!<tree>/bin/git sh-shim`; rodar um snippet com array
     deve disparar `Syntax error: "(" unexpected` (assinatura do dash).
4. **Roda a suíte** com `GIT_TEST_INSTALLED=$tree/bin`,
   `GIT_EXEC_PATH=$tree/libexec/git-core` e
   `GIT_TEST_EXEC_PATH=$tree/libexec/git-core`. O último é necessário
   porque `test-lib.sh:1397` chama `git --exec-path` (que retorna o path
   compile-time no `/nix/store`) e sobrescreve `GIT_EXEC_PATH`; o
   override `GIT_TEST_EXEC_PATH` na linha 1400 tem precedência.

## Smoke separado: caminho do embed-extrator on-demand

A preparação do test tree pré-grava os scripts em `libexec/git-core/` com
shebang reescrito, então **roda** sob nosso dash mas **não** exercita o
caminho do extrator on-demand (que cria um tmpdir e copia os blobs do
embed). Para validar o extrator com o `result/` pristine:

```bash
env -i HOME=/tmp PATH=$(pwd)/../result/bin ../result/bin/git submodule status
env -i HOME=/tmp PATH=$(pwd)/../result/bin ../result/bin/git filter-branch -h
```

Esses comandos disparam `unpins_run_embedded` (em `embed.c`) que mkdtemp,
extrai a closure, reescreve shebang, e roda.

## Bug de produção descoberto

`git difftool` e `git mergetool` invocam seus helpers (`git-difftool--helper`,
external merge tools) via `GIT_EXTERNAL_DIFF` / `run_command` direto — esse
caminho **não passa** por `execv_dashed_external`, então
`unpins_run_embedded` (em `embed.c`) **nunca dispara**. No binário shipado:

```
$ result/bin/git difftool --no-prompt HEAD~
error: cannot run git-difftool--helper: No such file or directory
```

O test suite **mascara** esse bug porque os scripts vivem pré-extraídos em
`libexec/git-core/`. Para corrigir em produção, o `embed.patch` precisa
interceptar em outro ponto (provavelmente em `run-command.c::prepare_cmd`
ou via wrapper de `git_external_diff`). Não é resolvido por essa
infraestrutura de teste.

## Tests que naturalmente serão pulados/falham

- **`t5550-http-fetch-dumb.sh` e amigos** (http): exigem apache em PATH (incluso
  no `shell.nix`). Se falharem por config CGI, é diagnóstico de ambiente, não
  do nosso binário.
- **t91xx (svn)**, **t96xx (cvs)**, **t9001 (send-email)**: dependem de perl
  modules; o `shell.nix` puxa os principais. Faltantes pulam graceful via
  `test_have_prereq`.
- **t7900 (subtree)**: requer `git-subtree` instalado; restauramos em libexec
  a partir de `contrib/subtree/`.

## Workdir

`$WORK` (default `/tmp/unpins-git-tests`) sobrevive entre runs. Para forçar
rebuild: `rm -rf $WORK`. Logs de build do stock git: `$WORK/build.log`.
Resultados de tests individuais: `$WORK/git-2.51.2/t/test-results/`.
