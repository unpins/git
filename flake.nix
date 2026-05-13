{
  description = "Standalone build of Git (multicall: helpers folded into single binary)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unpins-lib.url = "github:unpins/nix-lib";
  };

  outputs = { self, nixpkgs, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      pkgsFor = system: import nixpkgs { inherit system; };

      # ---------------------------------------------------------------------
      # Multicall override: drops multicall.[ch] into the source tree and
      # applies multicall.patch to fold every libexec helper into the main
      # `git` binary. Each helper file in libexec/git-core/ becomes a
      # symlink to git$X.
      #
      # Helpers folded:  daemon, http-backend, shell, sh-i18n--envsubst,
      #                  scalar, remote-curl (+ http/https/ftp/ftps aliases),
      #                  http-fetch, http-push, imap-send.
      #
      # Saves ~80 MB on a static install: each standalone helper carries its
      # own copy of musl + curl + openssl + expat (~10-14 MB); folding them
      # all into one shared 15 MB binary collapses that. We keep the
      # libexec/git-core/git-* symlinks so:
      #   - git's internal fork+exec finds the helpers via PATH (libexec
      #     is in GIT_EXEC_PATH); when the helper starts up handle_builtin
      #     sees argv[0] = "git-<helper>" and dispatches via mc_try_dispatch.
      #   - the layout matches every other unpins package that keeps
      #     BUILT_INS-style symlinks alongside the single binary (3-byte
      #     symlinks don't count as separate binaries).
      #
      # The patch is (i) git.c: 2-line edit (include + dispatch call in
      # handle_builtin), (ii) Makefile: replaces the standalone helper
      # link rules with an `unpins_mc_*` block that compiles each helper's
      # .o into the main git$X with -Dcmd_main=cmd_<name>_main. Anchors
      # are stable across git >= 2.51; the patch fails loud on drift.
      # ---------------------------------------------------------------------
      multicallOverride = pkgs: gitBase:
        # buildPackages so the coreutils/find tools used in postInstall
        # are build-host binaries, not cross-targets. For native builds
        # buildPackages == pkgs (same drvs) so this costs nothing.
        let bp = pkgs.buildPackages; in
        gitBase.overrideAttrs (old: {
          pname = (old.pname or "git") + "-multicall";

          patches = (old.patches or [ ]) ++ [ ./multicall.patch ];

          configureFlags = (old.configureFlags or [ ]) ++ [
            # Force-enable curl detection. autoconf's AC_CHECK_LIB tries to
            # link a tiny test against -lcurl alone; with static libs it fails
            # because curl drags openssl/zlib/nghttp2/idn2/psl/zstd/brotli/ssh2
            # into the link line. The cache var bypasses the probe and the
            # actual git build links via $(CURL_LIBCURL) which has the chain.
            "ac_cv_lib_curl_curl_global_init=yes"
          ];

          makeFlags = (old.makeFlags or [ ]) ++ [
            # libidn2 (gnulib) defines a global `error` that conflicts with
            # git's usage.c. NIX_LDFLAGS would also apply during configure
            # and break "C compiler can create executables"; keep this
            # make-time only.
            "LDFLAGS=-Wl,--allow-multiple-definition"
          ];

          # Skip the t/ test suite — we only ship binaries and the suite
          # takes ~15 min on the runners. Smoke-tested separately via apps.
          doCheck = false;
          doInstallCheck = false;

          # multicall.patch adds `#include "multicall.h"` to git.c; the
          # corresponding source files have to exist by the time we compile.
          postPatch = (old.postPatch or "") + ''
            cp ${./multicall.c} multicall.c
            cp ${./multicall.h} multicall.h
            chmod u+w multicall.c multicall.h
          '';

          # nixpkgs install copies hardlinks as separate files (different
          # inodes). After multicall the Makefile would normally hardlink
          # ~50 helper names to git$X; nixpkgs unlinks them into independent
          # 15 MB copies. Walk $out, hash each file, replace any duplicate
          # of bin/git with a relative symlink. ~12 collapses on a typical
          # native install.
          postInstall = (old.postInstall or "") + ''
            echo "=== Multicall postInstall: dedup hardlink-copies into symlinks ==="
            # On Windows cross the canonical name is git.exe, not git.
            canonical=""
            for cand in "$out/bin/git" "$out/bin/git.exe"; do
              if [ -f "$cand" ]; then canonical="$cand"; break; fi
            done
            if [ -z "$canonical" ]; then
              echo "ERROR: no canonical git binary in $out/bin/" >&2
              exit 1
            fi

            canonical_size=$(${bp.coreutils}/bin/stat -c%s "$canonical")
            canonical_sum=$(${bp.coreutils}/bin/sha256sum "$canonical" | ${bp.coreutils}/bin/cut -d' ' -f1)
            replaced=0

            while IFS= read -r f; do
              [ -z "$f" ] && continue
              [ "$f" = "$canonical" ] && continue
              [ -L "$f" ] && continue
              sum=$(${bp.coreutils}/bin/sha256sum "$f" | ${bp.coreutils}/bin/cut -d' ' -f1)
              if [ "$sum" = "$canonical_sum" ]; then
                target=$(${bp.coreutils}/bin/realpath --relative-to="$(${bp.coreutils}/bin/dirname "$f")" "$canonical")
                chmod -R u+w "$(${bp.coreutils}/bin/dirname "$f")" 2>/dev/null || true
                rm -f "$f"
                ln -s "$target" "$f"
                replaced=$((replaced + 1))
              fi
            done < <(${bp.findutils}/bin/find "$out" -type f -size "''${canonical_size}c")

            echo "Multicall dedup: replaced $replaced files (-> $canonical)"
          '';
        });

      # ---------------------------------------------------------------------
      # Native build (Linux/Darwin). pkgsStatic.gitMinimal yields a fully
      # static musl binary on Linux; on Darwin libSystem stays dynamic
      # (Apple constraint) but everything else is statically linked,
      # making the binary portable across any macOS without a /nix/store.
      # ---------------------------------------------------------------------
      mkNative = system:
        let pkgs = pkgsFor system;
        in multicallOverride pkgs pkgs.pkgsStatic.gitMinimal;
    in
    {
      packages = ulib.forAllNative (system: { default = mkNative system; });

      apps = ulib.forAllNative (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/git";
        };
      });
    };
}
