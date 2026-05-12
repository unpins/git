{
  description = "Standalone build of Git (multicall: helpers folded into single binary)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unpins-lib.url = "github:unpins/nix-lib/v1";
  };

  outputs = { self, nixpkgs, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      pkgsFor = system: import nixpkgs { inherit system; };

      multicallC = ./multicall.c;
      multicallH = ./multicall.h;

      # ---------------------------------------------------------------------
      # Multicall override: drops multicall.[ch] into the source tree and
      # patches git.c (2 lines: include + dispatch call) + Makefile to fold
      # every libexec helper into the main `git` binary. Each helper file
      # in libexec/git-core/ becomes a symlink to git$X.
      #
      # Helpers folded:  daemon, http-backend, shell, sh-i18n--envsubst,
      #                  scalar, remote-curl (+ http/https/ftp/ftps aliases),
      #                  http-fetch, http-push, imap-send.
      #
      # Saves ~80 MB on a static install: each standalone helper carries its
      # own copy of musl + curl + openssl + expat (~10–14 MB); folding them
      # all into one shared 15 MB binary collapses that.
      #
      # Anchors are stable across git ≥2.51:
      #   - git.c: `#include "trace2.h"`, `	strip_extension(args);`
      #   - Makefile: `git$X: git.o GIT-LDFLAGS $(BUILTIN_OBJS) $(GITLIBS)`
      #     and the standalone helper link rules (REMOTE_CURL_*, scalar$X,
      #     git-imap-send$X, git-http-fetch$X, git-http-push$X).
      # awk dies if any anchor is missing so version drift fails loud.
      # ---------------------------------------------------------------------
      multicallOverride = pkgs: gitBase:
        # buildPackages so the awk/coreutils/find tools used in patch and
        # install phases are build-host binaries, not cross-targets.
        # For native builds buildPackages == pkgs (same derivations), so
        # this costs nothing there; for cross-mingw it's required.
        let bp = pkgs.buildPackages; in
        gitBase.overrideAttrs (old: {
        pname = (old.pname or "git") + "-multicall";

        configureFlags = (old.configureFlags or []) ++ [
          # Force-enable curl detection. autoconf's AC_CHECK_LIB tries to
          # link a tiny test against -lcurl alone; with static libs it fails
          # because curl drags openssl/zlib/nghttp2/idn2/psl/zstd/brotli/ssh2
          # into the link line. The cache var bypasses the probe and the
          # actual git build links via $(CURL_LIBCURL) which has the chain.
          "ac_cv_lib_curl_curl_global_init=yes"
        ];

        makeFlags = (old.makeFlags or []) ++ [
          # libidn2 (gnulib) defines a global `error` that conflicts with
          # git's usage.c. NIX_LDFLAGS would also apply during the configure
          # phase and break "C compiler can create executables"; keep this
          # make-time only.
          "LDFLAGS=-Wl,--allow-multiple-definition"
        ];

        # Skip the full t/ test suite — we only ship binaries and the suite
        # takes ~15 min on the runners. Smoke-tested separately via apps.
        doCheck = false;
        doInstallCheck = false;

        postPatch = (old.postPatch or "") + ''
          echo "=== Multicall: dropping multicall.[ch] into source tree ==="
          cp ${multicallC} multicall.c
          cp ${multicallH} multicall.h
          chmod u+w multicall.c multicall.h

          echo "=== Multicall: patching git.c (2-line change) ==="
          ${bp.gawk}/bin/awk '
            /^#include "trace2\.h"$/ && !did_include {
              print
              print "#include \"multicall.h\""
              did_include = 1
              next
            }
            /^	strip_extension\(args\);$/ && !did_call {
              print
              print "	mc_try_dispatch(args);"
              did_call = 1
              next
            }
            { print }
            END {
              if (!did_include) { print "ERROR: include anchor not found" > "/dev/stderr"; exit 1 }
              if (!did_call)    { print "ERROR: dispatch anchor not found" > "/dev/stderr"; exit 1 }
            }
          ' git.c > git.c.new && mv git.c.new git.c

          echo "=== Multicall: patching Makefile ==="
          ${bp.gawk}/bin/awk '
            function emit_mc_block() {
              print "# === unpins multicall: fold helpers into git binary ==="
              print "unpins_mc_objs := multicall.o daemon.o http-backend.o shell.o sh-i18n--envsubst.o scalar.o"
              print "unpins_mc_programs := git-daemon$X git-http-backend$X git-shell$X git-sh-i18n--envsubst$X scalar$X"
              print "daemon.o:           EXTRA_CPPFLAGS = -Dcmd_main=cmd_daemon_main"
              print "http-backend.o:     EXTRA_CPPFLAGS = -Dcmd_main=cmd_http_backend_main"
              print "shell.o:            EXTRA_CPPFLAGS = -Dcmd_main=cmd_shell_main"
              print "sh-i18n--envsubst.o: EXTRA_CPPFLAGS = -Dcmd_main=cmd_sh_i18n_envsubst_main"
              print "scalar.o:           EXTRA_CPPFLAGS = -Dcmd_main=cmd_scalar_main"
              print "ifndef NO_CURL"
              print "unpins_mc_objs     += remote-curl.o http.o http-walker.o http-fetch.o imap-send.o"
              print "unpins_mc_programs += $(REMOTE_CURL_NAMES) git-http-fetch$X git-imap-send$X"
              print "remote-curl.o: EXTRA_CPPFLAGS = -Dcmd_main=cmd_remote_curl_main"
              print "http-fetch.o:  EXTRA_CPPFLAGS = -Dcmd_main=cmd_http_fetch_main"
              print "imap-send.o:   EXTRA_CPPFLAGS = -Dcmd_main=cmd_imap_send_main"
              print "EXTLIBS += $(CURL_LIBCURL) $(EXPAT_LIBEXPAT) $(IMAP_SEND_LDFLAGS)"
              print "ifndef NO_EXPAT"
              print "unpins_mc_objs     += http-push.o"
              print "unpins_mc_programs += git-http-push$X"
              print "http-push.o: EXTRA_CPPFLAGS = -Dcmd_main=cmd_http_push_main"
              print "endif"
              print "endif"
              print ""
              print "OBJECTS += multicall.o"
              print ""
              print "$(unpins_mc_programs): git$X"
              print "\t$(QUIET_LNCP)$(RM) $@ && ln $< $@ 2>/dev/null || ln -s $< $@ 2>/dev/null || cp $< $@"
              print ""
            }
            BEGIN { skip = 0 }
            skip > 0 { skip--; next }

            /^git\$X: git\.o GIT-LDFLAGS \$\(BUILTIN_OBJS\) \$\(GITLIBS\)$/ && !injected_mc {
              emit_mc_block()
              print "git$X: git.o GIT-LDFLAGS $(BUILTIN_OBJS) $(GITLIBS) $(unpins_mc_objs)"
              injected_mc = 1
              next
            }

            # Drop standalone helper link rules (header + 2 recipe lines = skip 2 after consuming header).
            /^git-imap-send\$X: imap-send\.o/                  { skip = 2; deleted_imap = 1;    next }
            /^git-http-fetch\$X: http\.o/                      { skip = 2; deleted_hfetch = 1;  next }
            /^git-http-push\$X: http\.o/                       { skip = 2; deleted_hpush = 1;   next }
            /^scalar\$X: scalar\.o GIT-LDFLAGS \$\(GITLIBS\)$/ { skip = 2; deleted_scalar = 1;  next }
            /^\$\(REMOTE_CURL_PRIMARY\): remote-curl\.o/       { skip = 2; deleted_primary = 1; next }
            # REMOTE_CURL_ALIASES rule has 4 recipe lines (line-continued ln/cp chain).
            /^\$\(REMOTE_CURL_ALIASES\): \$\(REMOTE_CURL_PRIMARY\)$/ { skip = 4; deleted_aliases = 1; next }

            { print }

            END {
              if (!injected_mc)      { print "ERROR: git$X anchor not found"  > "/dev/stderr"; exit 1 }
              if (!deleted_imap)     print "WARN: imap-send rule not deleted"           > "/dev/stderr"
              if (!deleted_hfetch)   print "WARN: http-fetch rule not deleted"          > "/dev/stderr"
              if (!deleted_hpush)    print "WARN: http-push rule not deleted"           > "/dev/stderr"
              if (!deleted_scalar)   print "WARN: scalar rule not deleted"              > "/dev/stderr"
              if (!deleted_primary)  print "WARN: REMOTE_CURL_PRIMARY rule not deleted" > "/dev/stderr"
              if (!deleted_aliases)  print "WARN: REMOTE_CURL_ALIASES rule not deleted" > "/dev/stderr"
            }
          ' Makefile > Makefile.new && mv Makefile.new Makefile
        '';

        # nixpkgs install copies hardlinks as separate files (different inodes).
        # After multicall, the Makefile would normally hardlink ~50 helper names
        # to git$X; nixpkgs unlinks them into independent 15 MB copies.
        # Walk $out, hash each file, replace any duplicate of bin/git with a
        # relative symlink. ~12 collapses on a typical native install.
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
