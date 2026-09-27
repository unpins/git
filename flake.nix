{
  description = "git as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      # Scripts git runs from its exec path. Upstream `make install` puts these
      # in libexec/git-core; here they go into the binary's ZIP instead. With
      # NO_PERL/NO_PYTHON the perl/python ones are the stubs that say so.
      gitScripts = [
        "git-difftool--helper" "git-filter-branch" "git-merge-octopus"
        "git-merge-one-file" "git-merge-resolve" "git-mergetool"
        "git-quiltimport" "git-request-pull" "git-submodule" "git-web--browse"
        "git-mergetool--lib" "git-sh-i18n" "git-sh-setup"
        "git-archimport" "git-cvsexportcommit" "git-cvsimport" "git-cvsserver"
        "git-send-email" "git-svn" "git-p4" "git-instaweb"
      ];

      # The ones that are commands; the rest are sourced libraries.
      execCmds = builtins.filter
        (n: !(builtins.elem n [ "git-mergetool--lib" "git-sh-i18n" "git-sh-setup" ]))
        gitScripts ++ [ "git-subtree" ];

      # ---------------------------------------------------------------------
      # One binary. multicall.patch folds the libexec helpers (daemon,
      # http-backend, shell, sh-i18n--envsubst, scalar, remote-curl and
      # friends) into git itself, dispatched by argv[0]. unpins-runtime.patch
      # links in busybox-w32's ash and applets plus unpin-vfs, and points
      # GIT_EXEC_PATH and the template dir at /__unpins_git__/, which the VFS
      # serves from the ZIP runtimeEmbed appends (see unpins_git.c). Every
      # child git would have exec'd from there is this binary instead, and
      # `git maintenance start` schedules it by its real path.
      #
      # `hostPkgs` is the set whose stdenv compiles git: busybox has to be
      # built by the same compiler, against the same libc.
      # ---------------------------------------------------------------------
      runtimeOverride = hostPkgs: gitBase:
        let
          # darwin renames busybox's symbols with llvm-objcopy, which needs
          # machine code: the engine's own no-LTO door there, the one x264
          # takes. Elsewhere lld -r lowers the bitcode itself.
          sys = hostPkgs.stdenv.buildPlatform.system;
          noLto = ulib.engineStdenv {
            pkgs = unpins-lib.inputs.nixpkgs.legacyPackages.${sys};
            toolchain = ulib.unpinToolchain sys;
            lto = false;
          };
          busybox = hostPkgs.callPackage ./busybox
            (if hostPkgs.stdenv.hostPlatform.isDarwin then { stdenv = noLto; } else { });
        in
        gitBase.overrideAttrs (old: {
          pname = (old.pname or "git") + "-multicall";

          patches = (old.patches or [ ]) ++ [
            ./multicall.patch
            ./scalar-rename-load-builtin.patch
            ./unpins-runtime.patch
          ];

          configureFlags = (old.configureFlags or [ ]) ++ [
            # Force-enable curl detection. autoconf's AC_CHECK_LIB tries to
            # link a tiny test against -lcurl alone; with static libs it fails
            # because curl drags openssl/zlib/nghttp2/idn2/psl/zstd/brotli/ssh2
            # into the link line. The cache var bypasses the probe and the
            # actual git build links via $(CURL_LIBCURL) which has the chain.
            "ac_cv_lib_curl_curl_global_init=yes"
          ];

          # nixpkgs bakes the build's bash into every script shebang and into
          # filter-branch's filter runner; the embedded ash reads neither
          # shebangs nor store paths.
          makeFlags = builtins.filter (f: !(hostPkgs.lib.hasPrefix "SHELL_PATH=" f))
            (old.makeFlags or [ ]) ++ [
              "SHELL_PATH=/bin/sh"
              # The man pages link the HTML docs, which don't ship: point
              # them at the published ones instead of the build's htmldir.
              "MAN_BASE_URL=https://git-scm.com/docs/"
            ];

          # Skip the t/ test suite — we only ship binaries and the suite
          # takes ~15 min on the runners.
          doCheck = false;
          doInstallCheck = false;

          postPatch = (old.postPatch or "") + ''
            cp ${./multicall.c} multicall.c
            cp ${./multicall.h} multicall.h
            cp ${./unpins_git.c} unpins_git.c
            cp ${./unpins_git.h} unpins_git.h
            cp ${ulib.vfsCore}/*.c ${ulib.vfsCore}/*.h .
            cp ${busybox}/lib/busybox.* .
            chmod u+w multicall.[ch] unpins_git.[ch] vfs.[ch] miniz.[ch] \
              unpin_zstd.[ch] zstddeclib.c busybox.*

            # What the ZIP can't say for itself: the templates' modes and
            # which exec-path entries are commands.
            {
              echo 'struct unpins_template { const char *path; int mode; };'
              echo 'static const struct unpins_template unpins_templates[] = {'
              for t in $(sed -n 's/^TEMPLATES += //p' templates/Makefile); do
                if [ -x "templates/$t" ]; then m=0755; else m=0644; fi
                echo "	{ \"$t\", $m },"
              done
              echo '	{ NULL, 0 }'
              echo '};'
              echo 'static const char *unpins_exec_cmds[] = {'
              for c in ${hostPkgs.lib.concatStringsSep " " execCmds}; do
                echo "	\"$c\","
              done
              echo '	NULL'
              echo '};'
            } > unpins_manifest.h
          '';

          # Stage what the ZIP carries, from the build tree: nixpkgs'
          # postInstall rewrites the installed scripts' sed/grep/awk/... into
          # store paths, which don't exist where this binary runs.
          preInstall = (old.preInstall or "") + ''
            st=$out/share/unpins-git
            install -d $st/libexec/git-core/mergetools $st/templates
            for s in ${hostPkgs.lib.concatStringsSep " " gitScripts}; do
              install -m644 "$s" $st/libexec/git-core/
            done
            install -m644 contrib/subtree/git-subtree $st/libexec/git-core/
            install -m644 mergetools/* $st/libexec/git-core/mergetools/
            cp -r templates/blt/. $st/templates/

            # gettext.sh and the locale dir: store paths, and nothing this
            # binary could find where it runs.
            sed -i 's#/nix/store/[a-z0-9]\{32\}-[^/"]*#/nonexistent#g' \
              $st/libexec/git-core/git-sh-i18n
            # The user's filters run in the same shell as every other script.
            substituteInPlace $st/libexec/git-core/git-filter-branch \
              --replace-fail '/bin/sh -c "$filter_commit"' 'sh -c "$filter_commit"'
            # Its install check takes `:` for the PATH separator; Windows' is `;`.
            substituteInPlace $st/libexec/git-core/git-subtree \
              --replace-fail 'test "''${PATH#"''${GIT_EXEC_PATH}:"}" = "$PATH" &&' \
                'test "''${PATH#"''${GIT_EXEC_PATH}:"}" = "$PATH" &&
            	test "''${PATH#"''${GIT_EXEC_PATH};"}" = "$PATH" &&'
            # `cd` can't enter the ZIP: list the embedded tools from here.
            tools=$(cd mergetools && echo *)
            substituteInPlace $st/libexec/git-core/git-mergetool--lib \
              --replace-fail '( cd "$MERGE_TOOLS_DIR" && ls )' \
                "( if test \"\$MERGE_TOOLS_DIR\" = \"\$(git --exec-path)/mergetools\"; then printf '%s\n' $tools; else cd \"\$MERGE_TOOLS_DIR\" && ls; fi )"

            # Modes come from unpins_manifest.h; executable files here would
            # get their shebangs pointed at the store by patchShebangs.
            find $st -type f -exec chmod 644 {} +
          '';

          # Upstream's exec path also holds a copy of git under every dashed
          # name it answers to (git, git-upload-pack, git-remote-https, ...),
          # and shells find them there. Here each is an empty entry, which
          # unpins_git.c and the ash exec hook read as "this binary, by that
          # name".
          postInstall = (old.postInstall or "") + ''
            st=$out/share/unpins-git/libexec/git-core
            for f in $out/libexec/git-core/*; do
              n=''${f##*/}
              [ -d "$f" ] || [ -e "$st/$n" ] || [ -e "$st/''${n%.exe}" ] || : > "$st/$n"
            done
            [ -e "$st/git${hostPkgs.stdenv.hostPlatform.extensions.executable}" ] \
              || { echo "no git in $out/libexec/git-core" >&2; exit 1; }
          '';

          postFixup = (old.postFixup or "") + ''
            if grep -rl /nix/store $out/share/unpins-git; then
              echo "store path in the embedded runtime" >&2
              exit 1
            fi
          '';
        });

      # The ZIP's root is /__unpins_git__/ at run time.
      stageRuntime = base: ''
        cp -r ${base}/share/unpins-git/. "$__unpin_stage/"
        chmod -R u+w "$__unpin_stage"
      '';

      # ---------------------------------------------------------------------
      # Cross-mingw build (x86_64 Windows). Runs on x86_64-linux runners.
      #
      # `mingwStaticCross` from nix-lib gives us the cross set with the
      # static-libs adapter + libidn2 `error` localize + libpsl/libunistring
      # propagation already in place. We thread a Schannel curl through
      # gitMinimal.override so curl avoids the openssl static-link autoconf
      # probe pitfalls (same recipe as `unpins/curl`).
      # ---------------------------------------------------------------------
      mkMingw = pkgs:
        let
          cross = ulib.mingwStaticCross pkgs;

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
            # Build-host tools used only in postInstall's rewrite of the
            # installed scripts, which don't ship (the ZIP takes them from the
            # build tree). buildPackages.* avoids spurious cross-mingw builds
            # of bash/gawk/sed/grep/coreutils.
            bash      = pkgs.bash;
            gawk      = pkgs.gawk;
            gnused    = pkgs.gnused;
            gnugrep   = pkgs.gnugrep;
            coreutils = pkgs.coreutils;
            curl      = curlSchannel;
            # The same pages the native build embeds; the doc toolchain runs
            # on the build host.
            withManual = true;
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
              # Hooks are `#!/bin/sh` scripts; with no sh on PATH, run them
              # with the ash linked into git.exe.
              ./mingw-unpins-sh.patch
              # git's manifest, actually embedded (git.rc names its type by
              # a macro windres doesn't have), with UTF-8 as the process code
              # page (Windows 10 1903+): the linked-in busybox takes argv,
              # environ, paths and child command lines through the ANSI APIs.
              ./mingw-utf8-manifest.patch
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
                # nedmalloc takes over malloc/free for the whole process,
                # busybox included, which then frees CRT-heap memory with it
                # (strdup, _fullpath) and gets blocks too loosely aligned for
                # its jmp_bufs. One allocator: the CRT's.
                "USE_NED_ALLOCATOR="
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
        runtimeOverride cross gitMingw;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "git";
      pkgsAttr = "gitMinimal";
      license = "GPL-2.0-only";

      # libpsl's .dat path is dead (curl's note says why); git's PREFIX only
      # feeds --man-path/--html-path, which name nothing on the target (the
      # native build carries the manual, windows is gitMinimal as is).
      removeReferences = [ "publicsuffix-list" "git-multicall" ];

      smoke = [ "--version" ];
      smokePattern = "^git version ";

      engine = "unpin-llvm";
      # What upstream's `make install` puts in bin/ besides git.
      multicall.programs = [{
        name = "git";
        aliases = [ "git-receive-pack" "git-upload-pack" "git-upload-archive"
                    "git-shell" "git-http-backend" "scalar" ];
      }];

      # nixpkgs turns the manual off for LLVM stdenvs; its tools (asciidoc,
      # xmlto) are build-host ones and work the same here.
      build = pkgs: runtimeOverride pkgs.pkgsStatic
        (pkgs.pkgsStatic.gitMinimal.override { withManual = true; });
      windowsBuild = mkMingw;

      runtimeEmbed = {
        native = pkgs: base: { runtimeStage = stageRuntime base; };
        windows = pkgs: base: { runtimeStage = stageRuntime base; };
      };
    };
}
