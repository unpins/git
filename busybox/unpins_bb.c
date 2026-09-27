
/* ---- unpins glue, appended to libbb/appletlib.c ---------------------- */

#if ENABLE_PLATFORM_MINGW32
# undef mingw_open
# undef mingw_stat
# undef mingw_lstat
# undef mingw_access
#else
# undef open
# undef stat
# undef lstat
# undef access
#endif

/* From unpin-vfs, compiled into the git side of the link. */
int unpin_vfs_is_virtual(const char *path);
int unpin_vfs_access(const char *path, int mode);
#if ENABLE_PLATFORM_MINGW32
const char *unpin_vfs_winpath(const char *path);
#else
int unpin_vfs_open(const char *path, int flags, ...);
int unpin_vfs_stat(const char *path, struct stat *st);
#endif

int unpins_bb_is_applet(const char *name)
{
	return find_applet_by_name(name) >= 0;
}

int unpins_bb_open(const char *path, int flags, ...)
{
	int mode = 0;

	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = va_arg(ap, int);
		va_end(ap);
	}
	if (path && unpin_vfs_is_virtual(path)) {
		/* the ZIP is read-only */
		flags &= ~(O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND);
#if ENABLE_PLATFORM_MINGW32
		const char *real = unpin_vfs_winpath(path);
		if (!real) {
			errno = ENOENT;
			return -1;
		}
		return open(real, flags);
#else
		return unpin_vfs_open(path, flags);
#endif
	}
	return open(path, flags, mode);
}

int unpins_bb_stat(const char *path, struct stat *st)
{
	if (path && unpin_vfs_is_virtual(path)) {
#if ENABLE_PLATFORM_MINGW32
		/* a temp copy, whose .tmp name says nothing of what it is */
		const char *real = unpin_vfs_winpath(path);
		if (!real) {
			errno = ENOENT;
			return -1;
		}
		if (stat(real, st) != 0)
			return -1;
#else
		if (unpin_vfs_stat(path, st) != 0)
			return -1;
#endif
		/* The ZIP keeps no modes; what's in it is meant to run. */
		if (S_ISREG(st->st_mode))
			st->st_mode |= 0555;
		return 0;
	}
	return stat(path, st);
}

int unpins_bb_lstat(const char *path, struct stat *st)
{
	if (path && unpin_vfs_is_virtual(path))
		return unpins_bb_stat(path, st);
	return lstat(path, st);
}

int unpins_bb_access(const char *path, int mode)
{
	if (path && unpin_vfs_is_virtual(path))
		return unpin_vfs_access(path, mode & ~W_OK);
	return access(path, mode);
}

/* The kernel can't exec a path inside the ZIP. An empty entry there names
 * one of git's own commands (`git`, `git-upload-pack`, ...): re-run this
 * binary under that name. Anything else is one of git's scripts: re-run it
 * as sh on the script. Returns only when `cmd` is not in the ZIP (or the
 * re-exec failed); the caller guarantees argv[-1] is writable, as tryexec's
 * ENOEXEC path does. */
void unpins_bb_exec_virtual(const char *cmd, char **argv, char **envp)
{
	struct stat st;
	char *name;
	size_t n;

	if (!unpin_vfs_is_virtual(cmd))
		return;
	if (unpins_bb_stat(cmd, &st) != 0) {
#if ENABLE_PLATFORM_MINGW32
		/* tryexec adds the .exe only after this */
		char *exe = xasprintf("%s.exe", cmd);
		int found = unpins_bb_stat(exe, &st) == 0;

		free(exe);
		if (!found)
			return;
#else
		return;
#endif
	}
	if (!S_ISREG(st.st_mode))
		return;
	if (st.st_size == 0) {
		name = xstrdup(bb_basename(cmd));
		n = strlen(name);
		if (n > 4 && strcasecmp(name + n - 4, ".exe") == 0)
			name[n - 4] = '\0';
		argv[0] = name;
		execve(bb_busybox_exec_path, argv, envp);
		free(name);
		return;
	}
	argv[0] = (char *)cmd;
	argv[-1] = (char *)"sh";
	execve(bb_busybox_exec_path, argv - 1, envp);
}

#if defined(__APPLE__)
# include <mach-o/dyld.h>
const char *unpins_bb_exec_path(void)
{
	static char path[PATH_MAX];

	if (!path[0]) {
		uint32_t n = sizeof(path);
		if (_NSGetExecutablePath(path, &n) != 0)
			path[0] = '\0';
	}
	return path;
}
#endif
