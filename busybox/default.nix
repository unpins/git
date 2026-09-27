# busybox-w32's ash plus the applets git's shell scripts call, compiled for
# the host into ONE relocatable object for the git link. Only the unpins_bb_*
# entry points stay global: busybox and git both define xmalloc, xwrite,
# die-style helpers and the like, and those must not meet.
#
# busybox-w32 rather than busybox because its ash runs on Windows too (fork
# emulated by re-running the binary), and one shell on every platform is the
# point. The same object, config and applets on linux, darwin and mingw.
{ lib, stdenv, buildPackages, fetchFromGitHub }:

let
  host = stdenv.hostPlatform;
  isMingw = host.isWindows;
  isDarwin = host.isDarwin;

  # What git's scripts (and the filters users hand to filter-branch) call.
  applets = [
    "ASH" "SH_IS_ASH"
    "AWK" "BASENAME" "CAT" "CHMOD" "CMP" "CP" "CUT" "DATE" "DIFF" "DIRNAME"
    "ECHO" "EGREP" "ENV" "EXPR" "FALSE" "FGREP" "FIND" "GREP" "HEAD" "LN" "LS"
    "MKDIR" "MKTEMP" "MV" "OD" "PRINTF" "PWD" "READLINK" "REALPATH" "RM"
    "RMDIR" "SED" "SEQ" "SLEEP" "SORT" "TAIL" "TEE" "TEST" "TEST1" "TEST2"
    "TOUCH" "TR" "TRUE" "UNAME" "UNIQ" "WC" "XARGS" "YES"
  ];
  features = [ "FEATURE_PREFER_APPLETS" "FEATURE_SH_STANDALONE" ];
  # darwin has no sendfile/utmp and the x86 SHA assembly is ELF-only.
  darwinOff = [ "FEATURE_USE_SENDFILE" "SHA1_HWACCEL" "SHA256_HWACCEL"
                "FEATURE_UTMP" "FEATURE_WTMP" ];

  sym = s: (lib.optionalString isDarwin "_") + s;
  entries = [ "unpins_bb_main" "unpins_bb_is_applet" ];
in
stdenv.mkDerivation {
  pname = "busybox-w32-for-git";
  version = "FRP-6075-g169694ebd";

  src = fetchFromGitHub {
    owner = "rmyorston";
    repo = "busybox-w32";
    rev = "FRP-6075-g169694ebd";
    hash = "sha256-5YIEDSBG8gqwQhz7ztTNCd1JKn2lI56GoVs9vV+hs/0=";
  };

  # The engine serves libc headers from a virtual root kbuild's fixdep can't
  # open; same patch as the catalog busybox.
  patches = [ ./fixdep-engine-vroot.patch ];

  depsBuildBuild = [ buildPackages.stdenv.cc ];
  # kconfig's own printf-style calls trip -Werror=format-security.
  hardeningDisable = [ "format" ];
  # Native objects: the relocatable link and symbol hiding below work on
  # machine code, not on bitcode.
  # mingw: no `.refptr.*` COMDATs either. Those are shared by section name
  # across the whole link, and one kept from here would be a local symbol
  # git's own references can't bind to.
  env.NIX_CFLAGS_COMPILE = "-fno-lto" + lib.optionalString isMingw " -mcmodel=small";

  postPatch = ''
    substituteInPlace libbb/appletlib.c \
      --replace-fail 'int main(int argc UNUSED_PARAM, char **argv)' \
                     'int unpins_bb_main(int argc UNUSED_PARAM, char **argv)'
    cat ${./unpins_bb.c} >> libbb/appletlib.c
    cat ${./unpins_bb.h} >> include/libbb.h
    sed -i '1i #define UNPINS_BB_NO_REDIRECT' win32/mingw.c
    substituteInPlace libbb/messages.c \
      --replace-fail 'const char bb_busybox_exec_path[]' \
                     '#undef bb_busybox_exec_path
    const char bb_busybox_exec_path[]'

    # Every exec ash attempts passes through tryexec; paths inside the ZIP
    # are re-run as this binary (unpins_bb_exec_virtual).
    substituteInPlace shell/ash.c \
      --replace-fail 'tryexec(const char *cmd, char **argv, char **envp)
    {
     repeat:' 'tryexec(const char *cmd, char **argv, char **envp)
    {
    	unpins_bb_exec_virtual(cmd, argv, envp);
     repeat:' \
      --replace-fail '	/* Workaround for libtool, which assumes the host is an MSYS2' \
                     '	unpins_bb_exec_virtual(cmd, argv, envp);
    	/* Workaround for libtool, which assumes the host is an MSYS2'
  '' + lib.optionalString isDarwin ''
    # GNU-isms libbb needs, and clang has no -static-libgcc.
    cp ${./darwin_compat.h} include/unpins_darwin_compat.h
    sed -i '1i #include "unpins_darwin_compat.h"' include/platform.h
    sed -i 's/-static-libgcc//' Makefile.flags
  '';

  # LD stays busybox's own `$(CC) -nostdlib`: ld64 has no -nostdlib.
  configurePhase = ''
    runHook preConfigure
    bbMakeFlags="HOSTCC=cc CC=$CC AR=$AR NM=$NM STRIP=$STRIP OBJCOPY=$OBJCOPY"
    make $bbMakeFlags ${if isMingw then "mingw64_defconfig" else "defconfig"} >/dev/null

    keep=" ${lib.concatStringsSep " " applets} "
    for a in $(grep -rhoE '//applet:IF_[A-Z0-9_]+' --include='*.c' . \
                 | sed 's|//applet:IF_||' | sort -u); do
      case "$keep" in *" $a "*) continue ;; esac
      case "$a" in PLATFORM_*) continue ;; esac
      sed -i "s/^CONFIG_$a=y/# CONFIG_$a is not set/" .config
    done
    for f in ${lib.concatStringsSep " " (applets ++ features)}; do
      sed -i "s/^# CONFIG_$f is not set/CONFIG_$f=y/" .config
    done
    for f in BUSYBOX ${lib.optionalString isDarwin (lib.concatStringsSep " " darwinOff)}; do
      sed -i "s/^CONFIG_$f=y/# CONFIG_$f is not set/" .config
    done
    { yes "" || true; } | make $bbMakeFlags oldconfig >/dev/null

    for f in ${lib.concatStringsSep " " (applets ++ features)}; do
      grep -qx "CONFIG_$f=y" .config || { echo "busybox: CONFIG_$f did not stick" >&2; exit 1; }
    done
    runHook postConfigure
  '';

  # Busybox's own final link fails by design (main is gone); everything it
  # would have linked is on its command line, kept in busybox_unstripped.out.
  buildPhase = ''
    runHook preBuild
    make -k -j$NIX_BUILD_CORES $bbMakeFlags busybox_unstripped${host.extensions.executable} || true
    objs=$(sed -n 's/.*-o busybox_unstripped\(.exe\)\{0,1\} //p' busybox_unstripped${host.extensions.executable}.out \
             | tr ' ' '\n' | grep -E '\.(o|a)$' | grep -v '^win32/resources/')
    [ -n "$objs" ] || { cat busybox_unstripped*.out >&2; exit 1; }
    ${if isDarwin then ''
      $LD -r -o busybox.o \
        ${lib.concatMapStringsSep " " (s: "-u ${sym s} -exported_symbol ${sym s}") entries} \
        $objs
    '' else ''
      $LD -r -o busybox.o ${lib.concatMapStringsSep " " (s: "-u ${sym s}") entries} \
        --start-group $objs --end-group
      $OBJCOPY ${lib.concatMapStringsSep " " (s: "--keep-global-symbol=${sym s}") entries} busybox.o
    ''}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 busybox.o $out/lib/busybox.o
    install -Dm644 .config $out/share/busybox.config
    runHook postInstall
  '';

  dontStrip = true;
  dontFixup = true;
}
