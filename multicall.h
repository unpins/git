/*
 * unpins multicall: dispatch helpers compiled into the main git binary.
 *
 * When git is invoked through a symlink whose name matches one of the
 * supported helpers (e.g. git-remote-https, git-daemon, scalar), the
 * dispatcher in handle_builtin() calls into the helper's renamed
 * cmd_main and exits, instead of falling through to the builtin
 * lookup table.
 */
#ifndef MULTICALL_H
#define MULTICALL_H

struct strvec;

/*
 * If args->v[0] matches a supported multicall helper, invoke it and
 * exit with its return code. Otherwise return so the caller can
 * proceed with normal builtin lookup.
 */
void mc_try_dispatch(struct strvec *args);

#endif /* MULTICALL_H */
