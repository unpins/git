/* GNU-isms busybox's libbb uses that darwin lacks; mostly for members ash never links. */
#if defined(__APPLE__) && !defined(__ASSEMBLER__) && !defined(UNPIN_BB_DARWIN_COMPAT)
#define UNPIN_BB_DARWIN_COMPAT
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <poll.h>
#include <time.h>
static inline void *mempcpy(void *d, const void *s, size_t n) { return (char *)memcpy(d, s, n) + n; }
#define __bswap32(x) __builtin_bswap32(x)
#define __bswap64(x) __builtin_bswap64(x)
static inline void explicit_bzero(void *p, size_t n) { memset_s(p, n, 0, n); }
static inline int sigisemptyset(const sigset_t *s) { return *s == 0; }
static inline int setresuid(uid_t r, uid_t e, uid_t s) { (void)s; return setreuid(r, e); }
static inline int setresgid(gid_t r, gid_t e, gid_t s) { (void)s; return setregid(r, e); }
static inline int ppoll(struct pollfd *f, nfds_t n, const struct timespec *t, const sigset_t *m) {
	sigset_t old; int r, ms = t ? (int)(t->tv_sec * 1000 + t->tv_nsec / 1000000) : -1;
	if (m) sigprocmask(SIG_SETMASK, m, &old);
	r = poll(f, n, ms);
	if (m) sigprocmask(SIG_SETMASK, &old, NULL);
	return r;
}
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
typedef struct { unsigned long b[16]; } cpu_set_t;
static inline int sched_getaffinity(int p, size_t s, void *m) { (void)p; (void)s; (void)m; errno = ENOSYS; return -1; }
#endif
