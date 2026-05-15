/* unpins/git embedded shell-script subsystem.
 *
 * Two halves:
 *   - unpins_run_embedded() is called from execv_dashed_external when
 *     the user requests a `git-<foo>` helper. If <foo> matches an
 *     embedded script it extracts the closure (script + transitively
 *     `.`-sourced helpers) into a fresh /tmp dir, fixes the requested
 *     script's shebang to point back at this binary's `sh-shim` builtin,
 *     forks via run_command, and rms the dir.
 *   - cmd_sh_shim() is the `git sh-shim <script> [args...]` builtin
 *     itself; it shims into the statically linked dash_main().
 */

#ifndef UNPINS_GIT_EMBED_H
#define UNPINS_GIT_EMBED_H

#include <stddef.h>
#include <stdint.h>

struct repository;

struct embed_entry {
    const char *name;          /* path under libexec/git-core/ in the
                                * extracted tree (e.g. "git-filter-branch",
                                * "git-sh-setup", "mergetools/vimdiff") */
    unsigned int mode;
    size_t size;
    const unsigned char *data;
    const uint16_t *deps;      /* indices into unpins_embed_index[] */
    uint8_t deps_n;
};

extern const struct embed_entry unpins_embed_index[];
extern const size_t unpins_embed_count;

/* short_name comes from execv_dashed_external (e.g. "filter-branch").
 * Returns the manifest entry whose name is "git-<short_name>", or NULL. */
const struct embed_entry *unpins_find_dashed(const char *short_name);

/* Called as the first step of execv_dashed_external. If short_name maps
 * to an embedded script, this function extracts the closure, runs it in
 * a child process, writes the exit status to *out_status, and returns 1.
 * Returns 0 on miss (caller falls through to its existing exec path) or
 * on any extraction error (also fall through). */
int unpins_run_embedded(const char **argv, int *out_status);

/* The `git sh-shim <script> [args...]` builtin entry. */
int cmd_sh_shim(int argc, const char **argv, const char *prefix,
                struct repository *repo);

#endif
