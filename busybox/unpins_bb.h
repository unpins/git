/* unpins: busybox inside the git binary. Appended to include/libbb.h, i.e.
 * after every system header libbb.h pulls in: a later re-include is then a
 * guarded no-op, so no declaration (or darwin/time64 asm label) is ever
 * rewritten through the macros below. */
#ifndef UNPINS_BB_H
#define UNPINS_BB_H

int unpins_bb_main(int argc, char **argv);
int unpins_bb_is_applet(const char *name);
void unpins_bb_exec_virtual(const char *cmd, char **argv, char **envp);

int unpins_bb_open(const char *path, int flags, ...);
int unpins_bb_stat(const char *path, struct stat *st);
int unpins_bb_lstat(const char *path, struct stat *st);
int unpins_bb_access(const char *path, int mode);

/* git's scripts live in the binary's ZIP; route busybox's lookups through
 * the VFS. On mingw `stat` etc. are object-like macros onto mingw_*, which
 * must keep renaming `struct stat`, so the redirect hooks the mingw_* call. */
#ifndef UNPINS_BB_NO_REDIRECT
# if ENABLE_PLATFORM_MINGW32
#  define mingw_open(...)    unpins_bb_open(__VA_ARGS__)
#  define mingw_stat(p, s)   unpins_bb_stat(p, s)
#  define mingw_lstat(p, s)  unpins_bb_lstat(p, s)
#  define mingw_access(p, m) unpins_bb_access(p, m)
# else
#  define open(...)          unpins_bb_open(__VA_ARGS__)
#  define stat(p, s)         unpins_bb_stat(p, s)
#  define lstat(p, s)        unpins_bb_lstat(p, s)
#  define access(p, m)       unpins_bb_access(p, m)
# endif
#endif

/* No /proc/self/exe on darwin. */
#if defined(__APPLE__)
const char *unpins_bb_exec_path(void);
# define bb_busybox_exec_path unpins_bb_exec_path()
#endif

#endif
