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

#ifdef _WIN32
# include <windows.h>
#endif

#ifndef PATH_MAX
# define PATH_MAX 4096
#endif

/* Windows mingw has SIGINT/SIGTERM but no SIGHUP; gate that one handler. */
#ifndef SIGHUP
# define UNPINS_HAVE_SIGHUP 0
#else
# define UNPINS_HAVE_SIGHUP 1
#endif

/* On mingw the embedded shell is the cosmocc-built `dash.exe`, extracted
 * into the same libexec/git-core/ as the scripts. Shebangs point at it;
 * git's parse_interpreter (compat/mingw.c) honors `#!/dash.exe` by
 * basename and resolves via PATH — GIT_EXEC_PATH is prepended to PATH by
 * setup_path() so the extracted file is reachable. The leading `/` is
 * required: parse_interpreter rejects shebangs without a `/` or `\`. */
#ifdef _WIN32
# define UNPINS_SHEBANG_LINE "#!/dash.exe\n"
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
#elif defined(_WIN32)
    DWORD n = GetModuleFileNameA(NULL, out, (DWORD)cap);
    if (n == 0 || n >= cap)
        return -1;
    /* Convert backslashes to forward slashes so the path is portable
     * between cmd, MSYS, and git's internal POSIX-style lookups. */
    for (DWORD i = 0; i < n; i++)
        if (out[i] == '\\') out[i] = '/';
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
#ifdef _WIN32
    /* mingw `signal()` has no SA_RESETHAND analog; just exit with a
     * conventional signal status (128 + sig) instead of re-raising. */
    _exit(128 + sig);
#else
    /* Re-raise after restoring default disposition (SA_RESETHAND) so
     * the process exits with the expected signal status. */
    raise(sig);
#endif
}

/* Allocate a fresh tmpdir for our libexec staging. Mirrors mkdtemp's
 * contract: writes the dir path into `out`, returns 0 on success. On
 * mingw we roll our own — mkdtemp is missing from the mingw-w64 CRT,
 * and tmp lives outside /tmp anyway (GetTempPath). */
static int unpins_mkdtemp(char *out, size_t cap)
{
#ifdef _WIN32
    char base[MAX_PATH];
    DWORD blen = GetTempPathA(MAX_PATH, base);
    if (blen == 0 || blen >= MAX_PATH)
        return -1;
    /* GetTempPath always returns a trailing separator; strip for
     * predictability when we append our own. */
    if (blen > 0 && (base[blen - 1] == '\\' || base[blen - 1] == '/'))
        base[blen - 1] = '\0';
    /* Try up to 32 randomized names. Collision is vanishingly rare
     * after process-id + tick-count mixing. */
    for (int attempt = 0; attempt < 32; attempt++) {
        unsigned int r =
            ((unsigned int)GetCurrentProcessId() << 16) ^
            (unsigned int)GetTickCount() ^
            ((unsigned int)attempt * 2654435761u);
        int n = snprintf(out, cap, "%s\\unpins-git.%08x", base, r);
        if (n < 0 || (size_t)n >= cap)
            return -1;
        if (CreateDirectoryA(out, NULL)) {
            /* Normalize separators — every other code path in this file
             * uses '/' and git's spawn paths accept either. */
            for (char *p = out; *p; p++)
                if (*p == '\\') *p = '/';
            return 0;
        }
        if (GetLastError() != ERROR_ALREADY_EXISTS)
            return -1;
    }
    return -1;
#else
    static const char tmpl[] = "/tmp/unpins-git.XXXXXX";
    if (cap < sizeof tmpl)
        return -1;
    memcpy(out, tmpl, sizeof tmpl);
    return mkdtemp(out) ? 0 : -1;
#endif
}

/* Install cleanup_signal for the signals we care about. SIGHUP isn't on
 * mingw; sigaction itself is a winpthreads-shaped no-op without RESETHAND
 * semantics, so signal() suffices for the platforms that have it. */
static void install_cleanup_handlers(void)
{
#ifdef _WIN32
    signal(SIGINT,  cleanup_signal);
    signal(SIGTERM, cleanup_signal);
#else
    struct sigaction sa = { 0 };
    sa.sa_handler = cleanup_signal;
    sa.sa_flags = SA_RESETHAND;
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
# if UNPINS_HAVE_SIGHUP
    sigaction(SIGHUP,  &sa, NULL);
# endif
#endif
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
#ifdef _WIN32
            (void)self_exe;
            if (write(fd, UNPINS_SHEBANG_LINE,
                      sizeof UNPINS_SHEBANG_LINE - 1) < 0) {
                close(fd); return -1;
            }
#else
            if (dprintf(fd, "#!%s sh-shim\n", self_exe) < 0) {
                close(fd); return -1;
            }
#endif
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

/* Pre-extract every entry in the embed index to a single tmpdir and
 * point GIT_EXEC_PATH at it. Called from cmd_main() so that ALL paths
 * which look up libexec/git-core helpers — execv_dashed_external,
 * run_command(GIT_EXTERNAL_DIFF=...), mergetool, fetch hooks — find the
 * scripts via the regular PATH lookup. Without this, helpers invoked
 * via GIT_EXTERNAL_DIFF (e.g. `git-difftool--helper`) get ENOENT because
 * unpins_run_embedded only fires from execv_dashed_external.
 *
 * Idempotent and policy-respecting:
 *   - If UNPINS_GIT_PREFAB is set (a previous invocation of this binary
 *     already prepared a tmpdir), no-op. Re-entries via the sh-shim
 *     shebang fall in this branch.
 *   - If GIT_EXEC_PATH is set externally (test framework or user
 *     override), no-op. The caller is asserting control over libexec
 *     and we honor that.
 *
 * On failure (mkdtemp / extract / setenv) we leave the env vars unset
 * and return; callers fall through to the pre-prefab paths (where
 * unpins_run_embedded acts as a per-helper fallback). */
void unpins_prefab_all(void)
{
    if (getenv("UNPINS_GIT_PREFAB"))
        return;
    if (getenv("GIT_EXEC_PATH"))
        return;

    char tmp_template[PATH_MAX];
    if (unpins_mkdtemp(tmp_template, sizeof tmp_template) != 0)
        return;
    snprintf(active_tmpdir, sizeof active_tmpdir, "%s", tmp_template);
    atexit(cleanup_tmpdir);
    install_cleanup_handlers();

    char self_exe[PATH_MAX];
    if (resolve_self_exe(self_exe, sizeof self_exe) != 0) {
        cleanup_tmpdir();
        return;
    }

    char exec_path[PATH_MAX];
    snprintf(exec_path, sizeof exec_path, "%s/libexec/git-core",
             active_tmpdir);
    if (mkdir_p(exec_path) != 0) {
        cleanup_tmpdir();
        return;
    }

    /* Compute the original libexec/git-core path next to the running
     * binary (../libexec/git-core relative to the bin dir). The C
     * helpers live there; we expose them differently per platform. */
    char libexec_orig[PATH_MAX];
    libexec_orig[0] = '\0';
    {
        const char *bin_slash = strrchr(self_exe, '/');
        if (bin_slash) {
            size_t prefix_len = (size_t)(bin_slash - self_exe);
            snprintf(libexec_orig, sizeof libexec_orig,
                     "%.*s/../libexec/git-core",
                     (int)prefix_len, self_exe);
        }
    }

#ifndef _WIN32
    /* Re-export the original libexec/git-core via symlinks so the C
     * helpers (sh-i18n--envsubst, remote-curl, http-backend, …) and the
     * builtin trampolines stay reachable when we point GIT_EXEC_PATH at
     * our tmpdir. The originals live at ../libexec/git-core relative to
     * the running binary in standard nixpkgs / Autotools layouts.
     *
     * Windows: skip — symlink() needs SeCreateSymbolicLinkPrivilege.
     * Instead we leave the originals where they are and prepend BOTH
     * <tmp>/libexec/git-core and the original libexec to PATH below.
     * git's lookup_prog walks PATH for `git-<foo>`/`git-<foo>.exe`,
     * so scripts resolve from <tmp> first, C helpers from the original. */
    if (libexec_orig[0]) {
        DIR *d = opendir(libexec_orig);
        if (d) {
            struct dirent *de;
            char src[PATH_MAX], dst[PATH_MAX], resolved[PATH_MAX];
            while ((de = readdir(d))) {
                if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
                    continue;
                snprintf(src, sizeof src, "%s/%s", libexec_orig, de->d_name);
                /* Skip directories. If we symlinked e.g. `mergetools/` to
                 * the real subdir, the embed extraction below would write
                 * `mergetools/<file>` *through* the symlink into the
                 * source tree, and rmrf during cleanup would follow the
                 * symlink and wipe the originals. Mergetools/* entries
                 * come from the embed index instead. */
                struct stat st;
                if (lstat(src, &st) == 0 && S_ISDIR(st.st_mode))
                    continue;
                /* realpath collapses ../ and resolves relative symlinks
                 * (libexec helpers in nixpkgs are symlinks like
                 * `git-daemon -> ../../bin/git`). Without this the symlink
                 * we create would point to a non-existent path under
                 * our tmpdir. */
                if (!realpath(src, resolved))
                    continue;
                snprintf(dst, sizeof dst, "%s/%s", exec_path, de->d_name);
                /* Best-effort; ignore failures. */
                (void)symlink(resolved, dst);
            }
            closedir(d);
        }
    }
#endif

    /* Extract embed entries, overwriting any pre-staged symlink for the
     * same path. mergetools/* lands in <exec_path>/mergetools/ which
     * extract_one creates via mkdir_p. */
    for (size_t i = 0; i < unpins_embed_count; i++) {
        const struct embed_entry *e = &unpins_embed_index[i];
        /* If a symlink was pre-staged for this name, remove it so the
         * fresh write isn't blocked by an existing file (O_CREAT|O_TRUNC
         * on a symlink follows the symlink, possibly outside tmpdir). */
        char dst[PATH_MAX];
        snprintf(dst, sizeof dst, "%s/%s", exec_path, e->name);
        unlink(dst);
        /* mode 0755 entries are executed via the kernel (shebang
         * matters); mode 0644 entries are `.`-sourced (shebang ignored).
         * extract_one no-ops the rewrite when the blob's magic isn't
         * `#!` — that covers dash.exe on Windows (MZ header, mode 0755). */
        int rewrite = (e->mode & 0111) ? 1 : 0;
        if (extract_one(active_tmpdir, e, rewrite, self_exe) != 0) {
            cleanup_tmpdir();
            return;
        }
    }

#ifdef _WIN32
    /* Prepend <tmp>/libexec/git-core (scripts + dash.exe) and the
     * original libexec/git-core (C helpers, scalar trampoline) to PATH.
     * git's parse_interpreter resolves shebang interpreters via
     * lookup_prog → PATH, and run_command spawning a script also walks
     * PATH for the script's basename. */
    {
        const char *old_path = getenv("PATH");
        char new_path[16384];
        snprintf(new_path, sizeof new_path, "%s;%s%s%s",
                 exec_path,
                 libexec_orig[0] ? libexec_orig : "",
                 libexec_orig[0] ? ";" : "",
                 old_path ? old_path : "");
        setenv("PATH", new_path, 1);
    }
#endif

    setenv("GIT_EXEC_PATH", exec_path, 1);
    setenv("UNPINS_GIT_PREFAB", exec_path, 1);
}

int unpins_run_embedded(const char **argv, int *out_status)
{
    /* If the prefab already exposed the helpers (or the caller set
     * GIT_EXEC_PATH explicitly — e.g. a test harness pointing at a
     * staged libexec), the regular PATH lookup will find the helper
     * there. Bypass the per-helper fallback so we don't shadow the
     * caller's libexec with our embed stubs. */
    if (getenv("UNPINS_GIT_PREFAB"))
        return 0;
    if (getenv("GIT_EXEC_PATH"))
        return 0;

    const struct embed_entry *root = unpins_find_dashed(argv[0]);
    if (!root) return 0;

    char tmp_template[PATH_MAX];
    if (unpins_mkdtemp(tmp_template, sizeof tmp_template) != 0)
        return 0;

    snprintf(active_tmpdir, sizeof active_tmpdir, "%s", tmp_template);
    atexit(cleanup_tmpdir);
    install_cleanup_handlers();

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
