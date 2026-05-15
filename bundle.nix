# Build inputs for the embedded shell-script subsystem of unpins/git.
#
# Produces three artefacts under $out:
#   - libdash.a + dash.h   :  static archive of dash's .o files (main →
#                             dash_main); statically linked into git$X
#                             and exposed as the `git sh-shim` built-in.
#   - embed_data.c         :  per-file `static const unsigned char` blobs
#                             of every shell script + helper + mergetool
#                             config that ships in libexec/git-core.
#   - embed_index.c        :  manifest table { name, mode, size, data*,
#                             deps[], deps_n } indexed by the runtime
#                             extractor; deps are static `.`-source edges
#                             (parsed at build time).
#
# Consumed from playground/git/flake.nix's multicallOverride.

{ pkgs }:

let
  # Use pkgsStatic so the .o files match the rest of git's link line
  # (musl on Linux, libSystem on darwin); host stdenv is what compiles.
  spkgs = pkgs.pkgsStatic;

  dashLib = spkgs.stdenv.mkDerivation {
    pname = "dash-lib";
    version = spkgs.dash.version;
    src = spkgs.dash.src;

    # main.c declares + defines `main`. Rename both forms; the rest of
    # dash is unaware. Preprocessor `-Dmain=dash_main` would also rewrite
    # `main_handler`, so we use sed on the one file that defines main.
    postPatch = ''
      sed -i \
        -e 's/^int main(/int dash_main(/' \
        -e 's/^main(/dash_main(/' \
        src/main.c
    '';

    # mknodes/mksyntax/mkinit/mksignames are build-host helper programs
    # that dash compiles and runs during its build to generate
    # nodes.[ch], syntax.[ch], etc. They're driven by CC_FOR_BUILD —
    # which autoconf resolves against the build platform's cc. pkgsStatic
    # hides the bare `cc` name from PATH, so without depsBuildBuild the
    # helper compiles fail with "cc: command not found".
    strictDeps = true;
    depsBuildBuild = [ pkgs.buildPackages.stdenv.cc ];

    configureFlags = [
      # We never link dash to a binary; libedit (line editing for
      # interactive sessions) is irrelevant and would drag ncurses into
      # the eventual git$X link line. Stick to the leaner config.
      "--without-libedit"
    ];

    # CFLAGS=-Os to keep the archive small. Disable LTO for predictable
    # symbol shape (helps when the linker complains).
    env.NIX_CFLAGS_COMPILE = "-Os -fno-lto";

    # `make` will fail at the dash binary link (no main symbol), but by
    # then every .o is on disk. -k continues past the failed link.
    # Bundle src/*.o AND src/bltin/*.o (echocmd / testcmd / printfcmd /
    # timescmd / conv_escape / test_file_access live there).
    #
    # Then partial-link them all into one dash_combined.o and demote
    # every global symbol except dash_main to local. This is critical:
    # dash exports its own xwrite() with semantics incompatible with
    # git's xwrite (dash returns 0 on full success, git returns
    # bytes-written; see write_in_full in wrapper.c). Without this
    # localization, git's --allow-multiple-definition picks dash's
    # xwrite and turns "wrote N bytes" into ENOSPC, breaking even
    # `git init` (template hooks copy fails). Localizing also avoids
    # any future namespace fights with `init`, `error`, `signal`, etc.
    buildPhase = ''
      runHook preBuild
      make -k -j$NIX_BUILD_CORES || true
      [ -f src/main.o ]              || (echo "ERROR: src/main.o not produced" >&2; exit 1)
      [ -f src/bltin/printf.o ]      || (echo "ERROR: bltin .o not produced" >&2; exit 1)
      $LD -r src/*.o src/bltin/*.o -o dash_combined.o
      $OBJCOPY --keep-global-symbol=dash_main dash_combined.o
      $AR rcs libdash.a dash_combined.o
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp libdash.a $out/
      cat > $out/dash.h <<'EOF'
      #ifndef UNPINS_DASH_H
      #define UNPINS_DASH_H
      int dash_main(int argc, char **argv);
      #endif
      EOF
      runHook postInstall
    '';

    dontStrip = true;  # Stripping a .a is not meaningful; preserves debug.
  };

  # All shipped libexec/git-core/ entries we want embedded. Names match
  # the on-disk filename (used both as embed-table key and as the
  # extracted file's relative path inside <tmp>/libexec/git-core/).
  scriptNames = [
    "git-archimport"        # NO_PERL stub
    "git-citool"            # Tcl trampoline (will fail without wish)
    "git-cvsexportcommit"   # NO_PERL stub
    "git-cvsimport"         # NO_PERL stub
    "git-cvsserver"         # NO_PERL stub
    "git-difftool--helper"
    "git-filter-branch"
    "git-gui--askpass"      # Tcl trampoline
    "git-instaweb"          # NO_PERL stub
    "git-merge-octopus"
    "git-merge-one-file"
    "git-merge-resolve"
    "git-mergetool"
    "git-mergetool--lib"
    "git-p4"                # NO_PYTHON stub
    "git-quiltimport"
    "git-request-pull"
    "git-sh-i18n"
    "git-sh-setup"
    "git-submodule"
    "git-subtree"
    "git-web--browse"
  ];

  embed = pkgs.runCommand "git-embed-bundle" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.xxd ];
    src = "${spkgs.gitMinimal}/libexec/git-core";
  } ''
    set -eu
    mkdir -p $out

    # Copy embedded files into a working tree so paths and modes are
    # predictable. Top-level scripts go straight into payload/, mergetools
    # subdir is mirrored.
    mkdir -p payload/mergetools
    ${pkgs.lib.concatMapStringsSep "\n" (n: ''
      cp "$src/${n}" "payload/${n}"
    '') scriptNames}
    cp -r "$src/mergetools/." payload/mergetools/
    chmod -R u+w payload

    # Build the file list (top-level scripts in declared order, then
    # mergetools/ alphabetically).
    : > files.list
    ${pkgs.lib.concatMapStringsSep "\n" (n: ''
      echo "${n}" >> files.list
    '') scriptNames}
    ( cd payload && find mergetools -type f | sort ) >> files.list

    # Per-file deps: parse `^\s*\.\s+...` lines.
    #   bare:           `. git-sh-setup`
    #   exec-path form: `. "$(git --exec-path)/git-sh-i18n"`
    # Anything else is a runtime-dynamic source we ignore here. For the
    # mergetool wrapper + library we additionally inject every
    # mergetools/* entry as a dep (covers the dynamic
    # `. "$MERGE_TOOLS_DIR/$tool"` lookup).
    : > deps.tsv
    while IFS= read -r f; do
      deps=""
      # static `.` lines
      while IFS= read -r line; do
        # bare-name form, optionally tab-indented
        bare=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*\.[[:space:]]+([A-Za-z0-9_-]+([.-][A-Za-z0-9_-]+)*)[[:space:]]*$/\1/p')
        if [ -n "$bare" ]; then deps="$deps $bare"; continue; fi
        # `. "$(git --exec-path)/<name>"` form
        exp=$(printf '%s\n' "$line" | sed -nE 's|^[[:space:]]*\.[[:space:]]+"\$\(git --exec-path\)/([^"]+)".*$|\1|p')
        if [ -n "$exp" ]; then deps="$deps $exp"; fi
      done < <(grep -E '^[[:space:]]*\.[[:space:]]+' "payload/$f" 2>/dev/null || true)

      # Hardcoded dynamic-source extension for the mergetool family
      case "$f" in
        git-mergetool|git-mergetool--lib|git-difftool--helper)
          for m in $(cd payload/mergetools && ls); do
            deps="$deps mergetools/$m"
          done
          ;;
      esac

      # Trim + dedup
      deps=$(printf '%s\n' $deps | awk 'NF && !seen[$0]++' | tr '\n' ' ')
      printf '%s\t%s\n' "$f" "$deps" >> deps.tsv
    done < files.list

    # Generate embed_data.c — one xxd-style array per file.
    {
      echo '/* Auto-generated by bundle.nix. Do not edit. */'
      echo '#include <stddef.h>'
      echo
      i=0
      while IFS= read -r f; do
        sym="unpins_blob_$i"
        # xxd -i emits both the array and a `..._len`. We strip the _len
        # variable since size is in embed_index.c.
        xxd -i -n "$sym" "payload/$f" \
          | sed -e '/^unsigned int .*_len/,$d'
        i=$((i + 1))
      done < files.list
    } > $out/embed_data.c

    # Generate embed_index.c — manifest table referencing the blobs.
    # Mode policy:
    #   mergetools/*  → 0644 (sourced configs)
    #   git-sh-setup, git-sh-i18n, git-mergetool--lib → 0644 (sourced libs)
    #   everything else → 0755 (executable scripts)
    #
    # deps[] is per-entry; deps_n is its length; deps elements are
    # uint16_t indices into unpins_embed_index[] (resolved by name).
    {
      echo '/* Auto-generated by bundle.nix. Do not edit. */'
      echo '#include <stddef.h>'
      echo '#include <stdint.h>'
      echo '#include "embed.h"'
      echo
      # Forward-declare the blob arrays.
      i=0
      while IFS= read -r _; do
        echo "extern const unsigned char unpins_blob_$i[];"
        i=$((i + 1))
      done < files.list
      echo

      # Emit per-entry deps arrays.
      idx=0
      while IFS=$'\t' read -r name deps; do
        depcount=0
        printf 'static const uint16_t deps_%d[] = {' "$idx"
        for d in $deps; do
          # find d's index by linearly scanning files.list (1-based not
          # used; uses 0-based as we iterate)
          ni=0
          dindex=""
          while IFS= read -r cand; do
            if [ "$cand" = "$d" ]; then dindex=$ni; break; fi
            ni=$((ni + 1))
          done < files.list
          if [ -n "$dindex" ]; then
            printf '%s%d' "$( [ $depcount -eq 0 ] || printf ', ' )" "$dindex"
            depcount=$((depcount + 1))
          else
            echo "warning: bundle.nix: unresolved dep '$d' for '$name'" >&2
          fi
        done
        printf '};\n'
        idx=$((idx + 1))
      done < deps.tsv
      echo

      # Emit the manifest table.
      echo 'const struct embed_entry unpins_embed_index[] = {'
      idx=0
      while IFS=$'\t' read -r name deps; do
        size=$(stat -c%s "payload/$name")
        case "$name" in
          mergetools/*|git-sh-setup|git-sh-i18n|git-mergetool--lib) mode=0644 ;;
          *) mode=0755 ;;
        esac
        depcount=0
        for d in $deps; do depcount=$((depcount + 1)); done
        printf '    { "%s", 0%o, %d, unpins_blob_%d, deps_%d, %d },\n' \
          "$name" "$mode" "$size" "$idx" "$idx" "$depcount"
        idx=$((idx + 1))
      done < deps.tsv
      echo '};'
      echo "const size_t unpins_embed_count = $idx;"
    } > $out/embed_index.c

    # Drop in the dash artefacts so the consumer can take them from one
    # output path.
    cp ${dashLib}/libdash.a $out/libdash.a
    cp ${dashLib}/dash.h    $out/dash.h
  '';
in
embed
