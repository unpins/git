{
  description = "Standalone build of Git (multicall: helpers folded into single binary)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unpins-lib.url = "github:unpins/nix-lib";
    # cosmocc is only consumed for the Windows-cross dash.exe blob in
    # mkMingw — Linux/Darwin embed dash via pkgsStatic + partial-link.
    # Native dash can't be cross-mingw-built (no fork/wait/termios on
    # mingw; libedit configure fails); cosmocc fills the gap with its
    # CreateProcessW-backed fork(). See docs/platforms/cosmocc.md.
    cosmocc.url = "github:unpins/cosmocc";
    cosmocc.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, unpins-lib, cosmocc }:
    let
      ulib = unpins-lib.lib;

      pkgsFor = system: import nixpkgs { inherit system; };

      # libidn2 (gnulib) defines a global `error` that collides with git's
      # usage.c at static-link time. Localize the symbol in the archive so
      # libidn2's internal callers still resolve to their now-local copy
      # and `error` outside the archive becomes uniquely git's. Avoids
      # `LDFLAGS=-Wl,--allow-multiple-definition`, which papers over the
      # collision instead of fixing it.
      #
      # Applied via `.overrideAttrs` threaded through curl/libpsl rather
      # than an overlay — overlays here invalidate `pkgsBuildHost.stdenv`
      # and force a full gcc rebuild for byte-identical output (see
      # nix-lib/flake.nix:204 comment).
      withLocalizedLibidn2 = staticPkgs:
        let
          libidn2Fixed = staticPkgs.libidn2.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              if [ -f "$out/lib/libidn2.a" ]; then
                chmod u+w "$out/lib/libidn2.a"
                $OBJCOPY --localize-symbol=error "$out/lib/libidn2.a"
              fi
            '';
          });
          # libpsl re-calls libidn2 in its args; re-thread the fixed one
          # so curl gets the same instance from both providers.
          libpslFixed = staticPkgs.libpsl.override { libidn2 = libidn2Fixed; };
          curlFixed = staticPkgs.curl.override {
            libidn2 = libidn2Fixed;
            libpsl  = libpslFixed;
          };
        in
        staticPkgs.gitMinimal.override { curl = curlFixed; };

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
      # `withEmbed` controls whether to apply embed.patch + bundle.nix.
      # Linux/Darwin: true (ships an embedded dash + the shell-script
      # helpers).  Cross-mingw: false until bundle.nix can build dash for
      # mingw (`docs/platforms/mingw.md` notes dash needs a separate
      # cross-mingw build — task tracked in
      # [[unpins-git-windows-port-in-progress]]).
      multicallOverride = { withEmbed ? true, cosmoccDash ? null }: pkgs: gitBase:
        # buildPackages so the coreutils/find tools used in postInstall
        # are build-host binaries, not cross-targets. For native builds
        # buildPackages == pkgs (same drvs) so this costs nothing.
        let
          bp = pkgs.buildPackages;
          # bundle.nix builds dash → libdash.a + the embed_*.c tables
          # (one xxd-style blob per shipped libexec/git-core script with
          # a per-script `. source` dep graph). embed.patch wires it all
          # into git's link line and adds a `git sh-shim` builtin that
          # invokes dash_main on the extracted script.
          #
          # On mingw, `cosmoccDash` must be set: bundle.nix appends the
          # cosmocc-built `dash.exe` to the embed table as an extra blob
          # (libdash.a is omitted from the link; shebangs point at the
          # extracted dash.exe, resolved via PATH by git's mingw spawn).
          bundle =
            if withEmbed
            then import ./bundle.nix { inherit pkgs cosmoccDash; }
            else null;
        in
        gitBase.overrideAttrs (old: {
          pname = (old.pname or "git") + "-multicall";

          patches = (old.patches or [ ]) ++ [
            ./multicall.patch
            ./scalar-rename-load-builtin.patch
          ] ++ nixpkgs.lib.optional withEmbed ./embed.patch;

          configureFlags = (old.configureFlags or [ ]) ++ [
            # Force-enable curl detection. autoconf's AC_CHECK_LIB tries to
            # link a tiny test against -lcurl alone; with static libs it fails
            # because curl drags openssl/zlib/nghttp2/idn2/psl/zstd/brotli/ssh2
            # into the link line. The cache var bypasses the probe and the
            # actual git build links via $(CURL_LIBCURL) which has the chain.
            "ac_cv_lib_curl_curl_global_init=yes"
          ];

          # Skip the t/ test suite — we only ship binaries and the suite
          # takes ~15 min on the runners. Smoke-tested separately via apps.
          doCheck = false;
          doInstallCheck = false;

          # multicall.patch adds `#include "multicall.h"` to git.c; the
          # corresponding source files have to exist by the time we compile.
          # embed.patch additionally references embed.h + dash.h and
          # links libdash.a + the four generated objects.
          postPatch = (old.postPatch or "") + ''
            cp ${./multicall.c}     multicall.c
            cp ${./multicall.h}     multicall.h
            chmod u+w multicall.c multicall.h
          '' + nixpkgs.lib.optionalString withEmbed (''
            cp ${./embed.c}         embed.c
            cp ${./embed.h}         embed.h
            cp ${./dash_shim.c}     dash_shim.c
            cp ${bundle}/embed_data.c  embed_data.c
            cp ${bundle}/embed_index.c embed_index.c
            cp ${bundle}/dash.h        dash.h
            chmod u+w embed.c embed.h dash_shim.c \
                      embed_data.c embed_index.c dash.h
          '' + nixpkgs.lib.optionalString (cosmoccDash == null) ''
            cp ${bundle}/libdash.a     libdash.a
            chmod u+w libdash.a
          '');

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

            # Embedded-script vestige cleanup: every script we ship
            # inside the binary becomes dead weight in libexec/git-core
            # (worse: the install-time shebangs point at a Nix store
            # bash that doesn't exist on the target). Remove them so
            # GIT_EXEC_PATH lookups fall through to our extract dir
            # only. The C-helper symlinks (git-daemon, etc.) stay —
            # they're routed by multicall, unrelated to embed.
            for n in git-archimport git-citool git-cvsexportcommit \
                     git-cvsimport git-cvsserver git-difftool--helper \
                     git-filter-branch git-gui--askpass git-instaweb \
                     git-merge-octopus git-merge-one-file git-merge-resolve \
                     git-mergetool git-mergetool--lib git-p4 \
                     git-quiltimport git-request-pull git-sh-i18n \
                     git-sh-setup git-submodule git-subtree git-web--browse; do
              ${bp.coreutils}/bin/rm -f "$out/libexec/git-core/$n"
            done
            ${bp.coreutils}/bin/rm -rf "$out/libexec/git-core/mergetools"
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
        in multicallOverride { } pkgs (withLocalizedLibidn2 pkgs.pkgsStatic);

      # ---------------------------------------------------------------------
      # Cross-mingw build (x86_64 Windows). Runs on x86_64-linux runners.
      #
      # `mingwStaticCross` from nix-lib gives us the cross set with the
      # static-libs adapter + libidn2 `error` localize + libpsl/libunistring
      # propagation already in place. We thread a Schannel curl through
      # gitMinimal.override so curl avoids the openssl static-link autoconf
      # probe pitfalls (same recipe as `unpins/curl`).
      #
      # Embed comes from two halves on mingw:
      #   - the shell scripts + mergetools/* are blobbed as on Linux/Darwin
      #     (xxd → embed_data.c), via bundle.nix.
      #   - dash itself can't be cross-mingw-built (no fork/wait/termios);
      #     instead `playground/dash`'s cosmocc build emits dash.exe (an
      #     APE → PE32+ binary with fork() implemented over CreateProcessW).
      #     bundle.nix appends it to the embed table; embed.c rewrites
      #     script shebangs to `#!/dash.exe`, and git's parse_interpreter
      #     (compat/mingw.c) resolves the basename via PATH at run time.
      # ---------------------------------------------------------------------
      mkMingw =
        let
          pkgs = pkgsFor "x86_64-linux";
          cross = ulib.mingwStaticCross pkgs;

          # cosmocc-built dash → APE binary, then `apelink -V 4` extracts
          # the Windows-only PE32+ image. Inlined here (rather than a
          # separate flake input) because the only consumer is mkMingw's
          # embed blob — same shape as `playground/dash/flake.nix`. The
          # cosmocc toolchain lives in its own derivation; build is short
          # enough that decoupling buys nothing.
          cosmoccTc = cosmocc.packages.x86_64-linux.cosmocc;
          cosmoccDash = pkgs.stdenvNoCC.mkDerivation rec {
            pname = "cosmocc-dash";
            version = "0.5.12";
            src = pkgs.fetchurl {
              url = "http://gondor.apana.org.au/~herbert/dash/files/dash-${version}.tar.gz";
              hash = "sha256-akdKxG6LCzKRbExg32lMggWNMpfYs4W3RQgDDKSo8oo=";
            };
            nativeBuildInputs = [ cosmoccTc pkgs.gnumake ];
            dontPatchELF = true;
            dontStrip = true;
            # cosmocc's --host triple disables autotools' run-time probes;
            # dash's configure only does link probes so this is fine.
            configureFlags = [ "--host=x86_64-pc-cosmo" "--enable-static" ];
            configurePhase = ''
              runHook preConfigure
              ./configure CC=cosmocc CXX=cosmoc++ AR=cosmoar RANLIB=cosmoranlib \
                $configureFlags
              runHook postConfigure
            '';
            buildPhase = ''
              runHook preBuild
              make -j$NIX_BUILD_CORES
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              # -V 4 strips the Linux/macOS/BSD halves of the fat APE so
              # we ship only the Windows PE — cuts the embedded blob to
              # ~640 KB vs ~1.1 MB for the full fat binary.
              apelink \
                -V ${toString cosmoccTc.passthru.apelinkPlatformBits.windows} \
                -o $out/bin/dash.exe \
                src/dash.com.dbg
              runHook postInstall
            '';
          };

          # Schannel-based static curl — same shape as unpins/curl.
          curlSchannel = ulib.mingwStaticBinary {
            pkg = cross.curl.override {
              opensslSupport = false;
              scpSupport     = false;
              http3Support   = false;
              libssh2        = null;
              brotliSupport  = false;
              zstdSupport    = false;
            };
            filterConfigureFlag = f: f != "--without-ssl";
            extraConfigureFlags = [ "--with-schannel" ];
            extraCFlags = [ "-DCURL_STATICLIB" "-DNGHTTP2_STATICLIB" "-DPSL_STATIC" ];
          };

          # gitMinimal with mingw-specific fixes layered on. Each item is
          # documented in `docs/platforms/mingw.md#git`.
          gitMingw = (cross.gitMinimal.override {
            # Build-host tools used only in postInstall shebang rewriting
            # of scripts we delete anyway. buildPackages.* avoids spurious
            # cross-mingw builds of bash/gawk/sed/grep/coreutils.
            bash      = pkgs.bash;
            gawk      = pkgs.gawk;
            gnused    = pkgs.gnused;
            gnugrep   = pkgs.gnugrep;
            coreutils = pkgs.coreutils;
            curl      = curlSchannel;
          }).overrideAttrs (old: {
            # make-shell-wrapper-hook drags target bash via
            # `targetPackages.runtimeShell`; gitMinimal has perlSupport=false
            # so wrapProgram is never called → hook is dead weight.
            nativeBuildInputs = builtins.filter
              (x: !(builtins.isAttrs x
                    && (x.pname or x.name or "") == "make-shell-wrapper-hook"))
              (old.nativeBuildInputs or [ ]);

            # autoconf's headers clash with compat/win32/*.h; git's Makefile
            # has a complete MINGW path. Skip configure → Makefile-only.
            dontConfigure = true;

            patches = (old.patches or [ ]) ++ [
              # compat/win32/pthread.h gates the pthread_sigmask stub by
              # __MINGW64_VERSION_MAJOR, but defines PTHREAD_H first so the
              # real winpthreads <pthread.h> is never included → implicit
              # decl. Drop the gate.
              ./mingw-pthread-sigmask.patch
            ];

            # Avoid libssp-0.dll (no static stack-protector runtime in
            # mingw-w64; -fno-stack-protector drops the dep entirely).
            env = (old.env or { }) // {
              NIX_CFLAGS_COMPILE =
                (old.env.NIX_CFLAGS_COMPILE or "") + " -fno-stack-protector";
            };

            makeFlags =
              # ZLIB_NG=1 has no static .a in cross zlib-ng.
              (builtins.filter (f: f != "ZLIB_NG=1") (old.makeFlags or [ ])) ++ [
                "uname_S=MINGW"             # else autoconf injects MSVC flags
                "MSYSTEM=MINGW64"           # else -D_USE_32BIT_TIME_T trips _WIN64
                "NO_GETTEXT=YesPlease"      # libintl.h absent
                "USE_LIBPCRE="              # MINGW block sets =YesPlease unconditionally
                "INSTALL=install"           # else hardcoded /bin/install fails
                # Schannel curl => no openssl in tree. imap-send.c
                # references openssl directly; route its TLS through curl
                # (which uses Schannel) and disable any direct openssl use.
                "NO_OPENSSL=YesPlease"
                "USE_CURL_FOR_IMAP_SEND=YesPlease"
                "CC=${pkgs.pkgsCross.mingwW64.stdenv.cc.targetPrefix}gcc"
                "AR=${pkgs.pkgsCross.mingwW64.stdenv.cc.targetPrefix}ar"
                "RC=${pkgs.pkgsCross.mingwW64.stdenv.cc.targetPrefix}windres -O coff"
                "CURL_CONFIG=${curlSchannel.dev}/bin/curl-config"
                # MINGW Makefile block sets EXTLIBS += -lws2_32 -lntdll
                # and multicall.patch adds EXTLIBS += $(CURL_LIBCURL)
                # $(EXPAT_LIBEXPAT); a command-line `EXTLIBS=...` CLOBBERS
                # those additions. Re-include -lcurl/-lexpat and the
                # whole static curl provider chain (nghttp2/psl/idn2/
                # unistring/iconv) plus Windows Schannel deps (crypt32/
                # bcrypt/advapi32 for CertFreeCertificateContext etc.).
                # Order matters: consumer before provider for single-pass
                # static linking.
                # Windows-system libs needed by Schannel curl:
                #   secur32   -> InitSecurityInterfaceA (SSPI provider table)
                #   iphlpapi  -> if_nametoindex (curl's interface scoping)
                #   crypt32   -> Cert* (Schannel cert chain validation)
                #   bcrypt    -> BCrypt* (Schannel symmetric/AEAD)
                #   ws2_32    -> sockets
                #   ntdll/advapi32 -> RtlGenRandom, registry, etc.
                "EXTLIBS=-lcurl -lexpat -lnghttp2 -lpsl -lidn2 -lunistring -liconv -lz -lws2_32 -lcrypt32 -lsecur32 -liphlpapi -lntdll -lbcrypt -ladvapi32"
              ];

            # nixpkgs install of MINGW git leaves bare-name symlinks
            # (`bin/git-http-backend` → `git`) that don't resolve because
            # the real file is `git.exe`. Re-link with `.exe` suffixed.
            postInstall = (old.postInstall or "") + ''
              for f in $out/bin/*; do
                if [ -L "$f" ] && [ ! -e "$f" ]; then
                  tgt=$(readlink "$f")
                  if [ -e "$out/bin/$tgt.exe" ] || [ -e "$tgt.exe" ]; then
                    rm "$f"; ln -s "$tgt.exe" "$f.exe"
                  fi
                fi
              done
            '';
          });
        in
        multicallOverride { inherit cosmoccDash; } pkgs gitMingw;
    in
    {
      packages =
        let nativePackages = ulib.forAllNative (system: { default = mkNative system; });
        in nativePackages // {
          x86_64-linux = nativePackages.x86_64-linux // {
            "windows-x86_64" = mkMingw;
          };
        };

      apps = ulib.forAllNative (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/git";
        };
      });
    };
}
