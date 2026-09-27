/*
 * unpins: git's shell scripts, mergetools and templates live in the ZIP at
 * the end of the binary (served by unpin-vfs under UNPINS_GIT_ROOT), and
 * busybox-w32's ash plus the applets the scripts call are linked in. Nothing
 * is ever written out: the kernel can't exec a path inside the ZIP, so every
 * such exec becomes this binary again, as `git` or as the shell.
 */
#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "copy.h"
#include "exec-cmd.h"
#include "gettext.h"
#include "path.h"
#include "repository.h"
#include "run-command.h"
#include "strbuf.h"
#include "strvec.h"
#include "unpins_git.h"
#include "unpins_manifest.h"
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

int unpins_bb_main(int argc, char **argv);
int unpins_bb_is_applet(const char *name);

int unpin_vfs_is_virtual(const char *path);
int unpin_vfs_open(const char *path, int flags, ...);
int unpin_vfs_access(const char *path, int mode);

static int in_zip(const char *path)
{
	return unpin_vfs_is_virtual(path) && !unpin_vfs_access(path, F_OK);
}

int unpins_dispatch(int *argcp, const char ***argvp, int *rc)
{
	int argc = *argcp;
	const char **argv = *argvp;
	const char *base, *p;
	char name[64];
	size_t n;

	if (argc >= 2 && !strcmp(argv[1], UNPINS_SH_FLAG)) {
		/* busybox-w32 rewrites argv[0] in place (lowercase, slashes) */
		static char sh[] = "sh";

		argv[1] = sh;
		*rc = unpins_bb_main(argc - 1, (char **)argv + 1);
		return 1;
	}
	if (argc >= 2 && !strcmp(argv[1], UNPINS_GIT_FLAG)) {
		argv[1] = "git";
		*argcp = argc - 1;
		*argvp = argv + 1;
		return 0;
	}

	if (!argv[0])
		return 0;
	for (base = p = argv[0]; *p; p++)
		if (is_dir_sep(*p))
			base = p + 1;
	n = strlen(base);
	if (n > 4 && !strcasecmp(base + n - 4, ".exe"))
		n -= 4;
	if (!n || n >= sizeof(name))
		return 0;
	for (size_t i = 0; i < n; i++)
		name[i] = tolower(base[i]);
	name[n] = '\0';
	if (!strcmp(name, "git") || starts_with(name, "git-") ||
	    !strcmp(name, "scalar") || !unpins_bb_is_applet(name))
		return 0;
	*rc = unpins_bb_main(argc, (char **)argv);
	return 1;
}

#ifdef GIT_WINDOWS_NATIVE
/*
 * git enters by wmain (-municode), which leaves the CRT's narrow __argv and
 * environ unset; busybox-w32 is a narrow main() program and uses both. Get
 * them the way its own startup would have, before git's wmain touches the
 * console, the environment or argv.
 */
typedef struct { int newmode; } unpins_startupinfo;
extern int __getmainargs(int *, char ***, char ***, int, unpins_startupinfo *);

int unpins_wdispatch(int *rc)
{
	unpins_startupinfo si = { 0 };
	char **argv, **env;
	int argc;

	if (__getmainargs(&argc, &argv, &env, 0, &si) < 0)
		return 0;
	return unpins_dispatch(&argc, (const char ***)&argv, rc);
}
#endif

const char *unpins_self_exe(void)
{
	static char *self;

	if (self)
		return self;
#if defined(GIT_WINDOWS_NATIVE)
	{
		wchar_t w[MAX_PATH];
		char u[MAX_PATH * 3];
		DWORD len = GetModuleFileNameW(NULL, w, ARRAY_SIZE(w));

		if (len && len < ARRAY_SIZE(w) && xwcstoutf(u, w, sizeof(u)) >= 0)
			self = xstrdup(u);
	}
#elif defined(__APPLE__)
	{
		char buf[PATH_MAX];
		uint32_t len = sizeof(buf);

		if (!_NSGetExecutablePath(buf, &len))
			self = real_pathdup(buf, 0);
	}
#else
	{
		struct strbuf sb = STRBUF_INIT;

		if (!strbuf_readlink(&sb, "/proc/self/exe", 0))
			self = strbuf_detach(&sb, NULL);
		strbuf_release(&sb);
	}
#endif
	if (!self)
		self = xstrdup("git");
	return self;
}

/*
 * The exec path in the ZIP holds git's scripts and, like upstream's
 * libexec/git-core, a name for every dashed command git itself provides:
 * those are empty entries. 1 for a script, 0 for such a name, -1 if absent.
 */
static int zip_entry(struct strbuf *path)
{
	char c;
	int fd, n;

	if (!in_zip(path->buf)) {
#ifdef GIT_WINDOWS_NATIVE
		strbuf_addstr(path, ".exe");
		if (in_zip(path->buf))
			return 0;
#endif
		return -1;
	}
	fd = unpin_vfs_open(path->buf, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, &c, 1);
	close(fd);
	return n > 0;
}

/*
 * The kernel can't exec from the ZIP: rewrite such a child to run this
 * binary, as git, as one of its dashed commands, or as the shell. So does
 * anything that needs a shell, so that git's shell is the same everywhere.
 */
void unpins_rewrite_child(struct child_process *cmd)
{
	struct strvec args = STRVEC_INIT;
	struct strbuf path = STRBUF_INIT;
	const char *arg0;

	if (!cmd->args.nr)
		return;
	arg0 = cmd->args.v[0];

	/* as prepare_shell_cmd() decides: no metacharacter, no shell */
	if (cmd->use_shell &&
	    strcspn(arg0, "|&;<>()$`\\\"' \t\n*?[#~=%") == strlen(arg0))
		cmd->use_shell = 0;

	if (cmd->use_shell) {
		strvec_pushl(&args, unpins_self_exe(), UNPINS_SH_FLAG, "-c", NULL);
		if (cmd->args.nr == 1)
			strvec_push(&args, arg0);
		else
			strvec_pushf(&args, "%s \"$@\"", arg0);
		strvec_pushv(&args, cmd->args.v);
		cmd->use_shell = 0;
	} else if (cmd->git_cmd || !strcmp(arg0, "git")) {
		strvec_pushl(&args, unpins_self_exe(), UNPINS_GIT_FLAG, NULL);
		strvec_pushv(&args, cmd->args.v + !cmd->git_cmd);
		cmd->git_cmd = 0;
	} else if (starts_with(arg0, "git-") && !has_dir_sep(arg0)) {
		strbuf_addf(&path, "%s/%s", git_exec_path(), arg0);
		switch (zip_entry(&path)) {
		case 1:
			strvec_pushl(&args, unpins_self_exe(), UNPINS_SH_FLAG,
				     path.buf, NULL);
			break;
		case 0:
			strvec_pushl(&args, unpins_self_exe(), UNPINS_GIT_FLAG,
				     arg0 + 4, NULL);
			break;
		default:
			strbuf_release(&path);
			return;
		}
		strvec_pushv(&args, cmd->args.v + 1);
		strbuf_release(&path);
	} else {
		return;
	}
	strvec_clear(&cmd->args);
	strvec_pushv(&cmd->args, args.v);
	strvec_clear(&args);
}

/* The exec path in the ZIP can't be listed: the build-time list instead. */
const char **unpins_exec_path_cmds(const char *path)
{
	return unpin_vfs_is_virtual(path) ? unpins_exec_cmds : NULL;
}

/*
 * The default template dir is in the ZIP, which has no directories to list
 * and keeps no modes: walk the build-time list instead. Same rules as
 * copy_templates_1(): never overwrite, shared perms on what's created.
 */
int unpins_copy_templates(const char *template_dir)
{
	struct strbuf src = STRBUF_INIT, dst = STRBUF_INIT;
	size_t src_len, dst_len;

	if (!unpin_vfs_is_virtual(template_dir))
		return 0;

	strbuf_addstr(&src, template_dir);
	strbuf_complete(&src, '/');
	src_len = src.len;
	strbuf_addstr(&dst, repo_get_common_dir(the_repository));
	strbuf_complete(&dst, '/');
	dst_len = dst.len;

	for (const struct unpins_template *t = unpins_templates; t->path; t++) {
		const char *slash;
		struct stat st;
		int ifd, ofd;

		for (slash = strchr(t->path, '/'); slash; slash = strchr(slash + 1, '/')) {
			strbuf_setlen(&dst, dst_len);
			strbuf_add(&dst, t->path, slash - t->path);
			safe_create_dir(the_repository, dst.buf, 1);
		}
		strbuf_setlen(&dst, dst_len);
		strbuf_addstr(&dst, t->path);
		if (!lstat(dst.buf, &st))
			continue;

		strbuf_setlen(&src, src_len);
		strbuf_addstr(&src, t->path);
		ifd = unpin_vfs_open(src.buf, O_RDONLY);
		if (ifd < 0)
			die_errno(_("cannot open template '%s'"), src.buf);
		ofd = open(dst.buf, O_WRONLY | O_CREAT | O_EXCL,
			   (t->mode & 0100) ? 0777 : 0666);
		if (ofd < 0 || copy_fd(ifd, ofd) || close(ofd))
			die_errno(_("cannot copy '%s' to '%s'"), src.buf, dst.buf);
		close(ifd);
		if (adjust_shared_perm(the_repository, dst.buf))
			die(_("cannot set permissions of '%s'"), dst.buf);
	}
	strbuf_release(&src);
	strbuf_release(&dst);
	return 1;
}
