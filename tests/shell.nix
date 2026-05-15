# Sandbox para rodar a suíte upstream `t/` do git contra o nosso binário
# multicall+embed. Não é usado pelo build; só pelo `run-tests.sh`.
#
# Inclui:
#   - toolchain nativa (cc, make, perl, python, tcl) para compilar `t/helper/
#     test-tool` e os helpers que os scripts de teste requerem;
#   - libs runtime que o build "stock" do git linka (não precisam ser
#     estáticas — esse build é descartável, usado só para gerar test-tool e
#     fixtures, não bate com o artefato shipado);
#   - dependências opt-in dos subsistemas: apache (t55xx http/cgi),
#     subversion (t91xx svn), cvs (t96xx cvs), perl modules para t9001
#     (send-email).
#
# `make test` no upstream graceful-skip cada subsistema se a dep faltar;
# estamos incluindo todos para maximizar cobertura.

let
  flake = builtins.getFlake "github:NixOS/nixpkgs/nixos-25.11";
in
{ pkgs ? import flake.outPath { } }:

let
  # Source tarball que o flake/nix-lib usa (pkgsStatic.gitMinimal). Expomos
  # como env var para run-tests.sh — assim não dependemos de `nix` em PATH
  # quando rodando com --pure.
  gitSrc = pkgs.pkgsStatic.gitMinimal.src;
in
pkgs.mkShellNoCC {
  packages = with pkgs; [
    # Build toolchain (host CC, não cross — esse git é descartável).
    gcc gnumake pkg-config
    perl python3 tcl

    # Headers/libs para `make all` do git.
    openssl curl expat zlib pcre2

    # Test-suite runtime (POSIX userland).
    gawk gnused coreutils findutils diffutils gnugrep
    less which

    # http/cgi tests (t55xx).
    apacheHttpd

    # svn tests (t91xx). `subversion` já inclui Perl bindings (SVN::*).
    subversion

    # cvs tests (t96xx, t9200).
    cvs

    # send-email + outros (t9001 e amigos).
    perlPackages.AuthenSASL
    perlPackages.NetSMTP
    perlPackages.NetSMTPSSL
    perlPackages.EmailSender
    perlPackages.IOSocketSSL
    perlPackages.MailSendmail
    perlPackages.IPCRun
    perlPackages.TermReadKey
    perlPackages.CGI
    perlPackages.DBI

    # quilt import (t9303).
    quilt
  ];

  GIT_SRC_TARBALL = gitSrc;
  GIT_SRC_VERSION = gitSrc.version or "2.51.2";

  shellHook = ''
    export GIT_TESTS_WORKDIR="''${GIT_TESTS_WORKDIR:-/tmp/unpins-git-tests}"
    echo "git-tests shell ready."
    echo "  GIT_TESTS_WORKDIR=$GIT_TESTS_WORKDIR"
    echo "  GIT_SRC_TARBALL=$GIT_SRC_TARBALL"
    echo "  Run: ./run-tests.sh [--quick | --all | <test.sh>...]"
  '';
}
