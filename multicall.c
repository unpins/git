#include "git-compat-util.h"
#include "strvec.h"
#include "trace2.h"
#include "multicall.h"

/*
 * Each helper's cmd_main has been renamed via -Dcmd_main=cmd_<name>_main
 * during compile (see Makefile patch), so the prototypes below match those
 * renamed entry points.
 */
extern int cmd_daemon_main(int argc, const char **argv);
extern int cmd_http_backend_main(int argc, const char **argv);
extern int cmd_shell_main(int argc, const char **argv);
extern int cmd_sh_i18n_envsubst_main(int argc, const char **argv);
extern int cmd_scalar_main(int argc, const char **argv);
#ifndef NO_CURL
extern int cmd_remote_curl_main(int argc, const char **argv);
extern int cmd_http_fetch_main(int argc, const char **argv);
extern int cmd_imap_send_main(int argc, const char **argv);
#ifndef NO_EXPAT
extern int cmd_http_push_main(int argc, const char **argv);
#endif
#endif

void mc_try_dispatch(struct strvec *args)
{
	const char *cmd = args->v[0];
	int (*helper)(int, const char **) = NULL;

	if      (!strcmp(cmd, "daemon"))             helper = cmd_daemon_main;
	else if (!strcmp(cmd, "http-backend"))       helper = cmd_http_backend_main;
	else if (!strcmp(cmd, "shell"))              helper = cmd_shell_main;
	else if (!strcmp(cmd, "sh-i18n--envsubst"))  helper = cmd_sh_i18n_envsubst_main;
	else if (!strcmp(cmd, "scalar"))             helper = cmd_scalar_main;
#ifndef NO_CURL
	else if (!strcmp(cmd, "remote-http")  ||
		 !strcmp(cmd, "remote-https") ||
		 !strcmp(cmd, "remote-ftp")   ||
		 !strcmp(cmd, "remote-ftps"))        helper = cmd_remote_curl_main;
	else if (!strcmp(cmd, "http-fetch"))         helper = cmd_http_fetch_main;
	else if (!strcmp(cmd, "imap-send"))          helper = cmd_imap_send_main;
#ifndef NO_EXPAT
	else if (!strcmp(cmd, "http-push"))          helper = cmd_http_push_main;
#endif
#endif

	if (!helper)
		return;

	const char **argv_copy = NULL;
	int ret;

	if (args->nr)
		DUP_ARRAY(argv_copy, args->v, args->nr + 1);

	/* Re-prefix argv[0] with "git-" for helpers whose own code paths
	 * fork+exec themselves by argv[0] (e.g. daemon copies its argv into
	 * the per-connection child via cld_argv; if argv[0] is bare "daemon"
	 * the child execvp's PATH first hit is /usr/bin/daemon — the BSD
	 * daemon(1) — and the spawn dies with "unrecognized option --serve").
	 * Stock git ships these as standalone binaries named "git-<foo>", so
	 * their argv[0] is already prefixed in the upstream code path; the
	 * multicall short-circuit must restore that invariant. scalar uses
	 * its bare basename in subcommand dispatch logic and doesn't fork by
	 * argv[0], so we leave it alone. */
	char prefixed[256];
	if (argv_copy && strcmp(cmd, "scalar") != 0) {
		snprintf(prefixed, sizeof prefixed, "git-%s", cmd);
		argv_copy[0] = prefixed;
	}

	trace2_cmd_name(cmd);
	ret = helper(args->nr, argv_copy);
	strvec_clear(args);
	free(argv_copy);
	exit(ret);
}
