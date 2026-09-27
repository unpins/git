#ifndef UNPINS_GIT_H
#define UNPINS_GIT_H

struct child_process;

/* argv[1] that makes this binary run the rest of argv as the shell. */
#define UNPINS_SH_FLAG "--unpins-sh"
/*
 * argv[1] that makes it git whatever its file is called: re-running
 * ourselves as git-upload-pack's child must not come back as upload-pack.
 */
#define UNPINS_GIT_FLAG "--unpins-git"

/*
 * Runs busybox for argv[0] named after one of its applets, or the shell for
 * `git --unpins-sh ...`, and returns 1 with the exit code in *rc. Otherwise
 * returns 0, having dropped a leading --unpins-git from argc and argv.
 */
int unpins_dispatch(int *argc, const char ***argv, int *rc);
/* Windows: the same, called first thing in wmain() with the narrow argv. */
int unpins_wdispatch(int *rc);

const char *unpins_self_exe(void);
void unpins_rewrite_child(struct child_process *cmd);
int unpins_copy_templates(const char *template_dir);
/* NULL-terminated `git-*` commands in `path` when it is in the ZIP, else NULL. */
const char **unpins_exec_path_cmds(const char *path);

#endif
