# Sandbox for running git's upstream `t/` suite against the built binary.
# Not used by the build; only by run-tests.sh.
#
# The nixpkgs is the one the flake builds with, so the source tarball is the
# very version the binary was built from.
let
  flake = builtins.getFlake (toString ../.);
  nixpkgs = flake.inputs.unpins-lib.inputs.nixpkgs;
in
{ pkgs ? import nixpkgs { } }:

pkgs.mkShellNoCC {
  packages = with pkgs; [
    # The stock build that provides t/helper/test-tool; thrown away after.
    gcc gnumake pkg-config perl python3
    openssl curl expat zlib pcre2

    # What the test scripts run on the host side.
    gawk gnused coreutils findutils diffutils gnugrep less which
  ];

  GIT_SRC_TARBALL = pkgs.gitMinimal.src;
  GIT_SRC_VERSION = pkgs.gitMinimal.version;
}
