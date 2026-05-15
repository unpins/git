/* On-demand extractor for embedded git shell scripts.
 *
 * Flow when the user runs `git filter-branch ...`:
 *   1. cmd_main → run_argv → handle_builtin → no builtin match for
 *      "filter-branch" → execv_dashed_external(["filter-branch", ...])
 *   2. Patched execv_dashed_external calls unpins_run_embedded() first.
 *   3. unpins_find_dashed("filter-branch") returns the embed_entry for
 *      "git-filter-branch". We mkdtemp("/tmp/unpins-git.XXXXXX"), then
 *      BFS the static `.`-source closure ({git-filter-branch,
 *      git-sh-setup, git-sh-i18n}), write each into <tmp>/libexec/git-core/
 *      with the correct mode, rewriting only the requested-script's
 *      shebang to `#!<self_exe> sh-shim`. Sourced helpers keep their
 *      original first line — they're `.`-sourced, the kernel never reads
 *      that line.
 *   4. Set GIT_EXEC_PATH=<tmp>/libexec/git-core so any `git foo` invoked
 *      from inside the script (and any later libexec lookups) hit the
 *      same tmp tree.
 *   5. run_command on `<tmp>/libexec/git-core/git-filter-branch <args>`.
 *      Kernel reads the rewritten shebang, execve's <self_exe>, which
 *      re-enters cmd_main → built-in `sh-shim` → cmd_sh_shim →
 *      dash_main(<script>, args).
 *   6. After run_command returns, rmrf the tmpdir and exit() with the
 *      child status (caller's existing code path). */

#define _GNU_SOURCE  /* for execvp / child_process */

#include "git-compat-util.h"
#include "run-command.h"
#include "strvec.h"
#include "embed.h"

#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <dirent.h>
#include <limits.h>

#ifdef __APPLE__
# include <mach-o/dyld.h>
#endif

#ifndef PATH_MAX
# define PATH_MAX 4096
#endif

/* ----- self-exe resolution ------------------------------------------- */

static int resolve_self_exe(char *out, size_t cap)
{
#ifdef __APPLE__
    uint32_t sz = (uint32_t)cap;
    char buf[PATH_MAX];
    if (_NSGetExecutablePath(buf, &sz) != 0)
        return -1;
    if (!realpath(buf, out))
        return -1;
    return 0;
#else
    ssize_t n = readlink("/proc/self/exe", out, cap - 1);
    if (n < 0)
        return -1;
    out[n] = '\0';
    return 0;
#endif
}

/* ----- recursive mkdir / rm -r --------------------------------------- */

static int mkdir_p(const char *path)
{
    char buf[PATH_MAX];
    size_t len = strlen(path);
    if (len >= sizeof buf) { errno = ENAMETOOLONG; return -1; }
    memcpy(buf, path, len + 1);
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(buf, 0700) != 0 && errno != EEXIST)
                return -1;
            *p = '/';
        }
    }
    if (mkdir(buf, 0700) != 0 && errno != EEXIST)
        return -1;
    return 0;
}

static int rmrf(const char *path)
{
    DIR *d = opendir(path);
    if (!d) {
        if (errno == ENOTDIR || errno == ENOENT)
            return unlink(path);
        return -1;
    }
    struct dirent *e;
    char child[PATH_MAX];
    int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        int n = snprintf(child, sizeof child, "%s/%s", path, e->d_name);
        if (n < 0 || (size_t)n >= sizeof child) { rc = -1; continue; }
        if (rmrf(child) != 0)
            rc = -1;
    }
    closedir(d);
    if (rmdir(path) != 0)
        rc = -1;
    return rc;
}

/* ----- cleanup hooks -------------------------------------------------- */

static char active_tmpdir[PATH_MAX];

static void cleanup_tmpdir(void)
{
    if (active_tmpdir[0]) {
        rmrf(active_tmpdir);
        active_tmpdir[0] = '\0';
    }
}

static void cleanup_signal(int sig)
{
    /* rmrf is not async-signal-safe; accepted v1 trade-off (alternative
     * is leaving the tmpdir behind for /tmp's reaper to handle). */
    cleanup_tmpdir();
    /* Re-raise after restoring default disposition (SA_RESETHAND) so
     * the process exits with the expected signal status. */
    raise(sig);
}

/* ----- closure walk --------------------------------------------------- */

static size_t collect_closure(const struct embed_entry *root, uint16_t *out)
{
    /* Bitmap dedup; queue head/tail walks deps. unpins_embed_count is
     * tens of entries, an alloca of N bytes is fine. */
    unsigned char *seen = alloca(unpins_embed_count);
    memset(seen, 0, unpins_embed_count);

    size_t root_idx = (size_t)(root - unpins_embed_index);
    size_t head = 0, tail = 0;
    out[tail++] = (uint16_t)root_idx;
    seen[root_idx] = 1;

    while (head < tail) {
        const struct embed_entry *e = &unpins_embed_index[out[head++]];
        for (uint8_t i = 0; i < e->deps_n; i++) {
            uint16_t d = e->deps[i];
            if (d < unpins_embed_count && !seen[d]) {
                seen[d] = 1;
                out[tail++] = d;
            }
        }
    }
    return tail;
}

/* ----- per-file extract ---------------------------------------------- */

static int extract_one(const char *root,
                       const struct embed_entry *e,
                       int rewrite_shebang,
                       const char *self_exe)
{
    char dst[PATH_MAX];
    int n = snprintf(dst, sizeof dst, "%s/libexec/git-core/%s",
                     root, e->name);
    if (n < 0 || (size_t)n >= sizeof dst) { errno = ENAMETOOLONG; return -1; }

    /* mkdir parent */
    char *slash = strrchr(dst, '/');
    if (slash) {
        *slash = '\0';
        if (mkdir_p(dst) != 0) return -1;
        *slash = '/';
    }

    int fd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, e->mode);
    if (fd < 0) return -1;

    if (rewrite_shebang && e->size >= 2 &&
        e->data[0] == '#' && e->data[1] == '!') {
        const unsigned char *nl = memchr(e->data, '\n', e->size);
        if (nl) {
            if (dprintf(fd, "#!%s sh-shim\n", self_exe) < 0) {
                close(fd); return -1;
            }
            size_t off = (size_t)(nl + 1 - e->data);
            if (write(fd, nl + 1, e->size - off) < 0) {
                close(fd); return -1;
            }
        } else if (write(fd, e->data, e->size) < 0) {
            close(fd); return -1;
        }
    } else if (e->size && write(fd, e->data, e->size) < 0) {
        close(fd); return -1;
    }

    return close(fd);
}

/* ----- public API ----------------------------------------------------- */

const struct embed_entry *unpins_find_dashed(const char *short_name)
{
    char buf[256];
    int n = snprintf(buf, sizeof buf, "git-%s", short_name);
    if (n < 0 || (size_t)n >= sizeof buf) return NULL;
    for (size_t i = 0; i < unpins_embed_count; i++) {
        if (!strcmp(unpins_embed_index[i].name, buf))
            return &unpins_embed_index[i];
    }
    return NULL;
}

int unpins_run_embedded(const char **argv, int *out_status)
{
    const struct embed_entry *root = unpins_find_dashed(argv[0]);
    if (!root) return 0;

    char tmp_template[] = "/tmp/unpins-git.XXXXXX";
    if (!mkdtemp(tmp_template)) return 0;

    /* Reuse a static slot for the cleanup handlers. snprintf instead
     * of memcpy keeps ASAN happy if PATH_MAX disagrees. */
    snprintf(active_tmpdir, sizeof active_tmpdir, "%s", tmp_template);
    atexit(cleanup_tmpdir);
    {
        struct sigaction sa = { 0 };
        sa.sa_handler = cleanup_signal;
        sa.sa_flags = SA_RESETHAND;
        sigaction(SIGINT,  &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGHUP,  &sa, NULL);
    }

    char self_exe[PATH_MAX];
    if (resolve_self_exe(self_exe, sizeof self_exe) != 0) {
        cleanup_tmpdir();
        return 0;
    }

    uint16_t *closure = alloca(unpins_embed_count * sizeof *closure);
    size_t n = collect_closure(root, closure);
    for (size_t i = 0; i < n; i++) {
        const struct embed_entry *e = &unpins_embed_index[closure[i]];
        if (extract_one(tmp_template, e, e == root, self_exe) != 0) {
            cleanup_tmpdir();
            return 0;
        }
    }

    char exec_path[PATH_MAX];
    snprintf(exec_path, sizeof exec_path, "%s/libexec/git-core",
             tmp_template);
    setenv("GIT_EXEC_PATH", exec_path, 1);

    char abs_argv0[PATH_MAX];
    snprintf(abs_argv0, sizeof abs_argv0, "%s/%s",
             exec_path, root->name);

    /* Build the child argv. Using a strvec keeps the original argv
     * untouched (the caller may still want it for trace messages). */
    struct child_process cmd = CHILD_PROCESS_INIT;
    strvec_push(&cmd.args, abs_argv0);
    for (int i = 1; argv[i]; i++)
        strvec_push(&cmd.args, argv[i]);
    cmd.silent_exec_failure = 1;
    cmd.clean_on_exit = 1;
    cmd.wait_after_clean = 1;
    cmd.trace2_child_class = "dashed";

    *out_status = run_command(&cmd);

    cleanup_tmpdir();
    return 1;
}
