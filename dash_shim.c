/* `git sh-shim <script> [args...]` — invokes the statically linked dash
 * on the given script. Reached via the shebang the embed extractor writes
 * into the temp script (`#!<self> sh-shim`).
 *
 * dash takes argv exactly the way /bin/sh does: argv[0] is its name (used
 * for $0 / errors / ps display), argv[1] is the script path, argv[2..]
 * are the script's positional parameters.
 *
 * We're handed argv = ["sh-shim", "<script>", ...] by git's run_argv —
 * dropping "sh-shim" by overwriting argv[0] to "dash" gives dash exactly
 * what it expects without a memmove. */

#include "git-compat-util.h"
#include "embed.h"
#include "dash.h"

int cmd_sh_shim(int argc, const char **argv, const char *prefix,
                struct repository *repo)
{
    (void)prefix;
    (void)repo;

    if (argc < 2 || !strcmp(argv[1], "-h")) {
        /* Convention all git builtins follow: rc 129 + usage on stdout
         * for -h; t/t0012-help.sh asserts this for every entry in the
         * builtin table. Without the explicit branch dash sees "-h" as
         * its own flag and dies "Illegal option -h" on stderr (rc 2). */
        FILE *out = (argc >= 2 && !strcmp(argv[1], "-h")) ? stdout : stderr;
        fprintf(out, "usage: git sh-shim <script> [args...]\n");
        return 129;
    }

    /* dash's main() accepts char**, not const char**. The argv buffer
     * lives in cmd_main's strvec which already owns mutable strings, so
     * the cast is safe in this codepath. */
    char **a = (char **)argv;
    a[0] = (char *)"dash";

    return dash_main(argc, a);
}
