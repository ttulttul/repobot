#include "CProcess.h"
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>
int rb_spawn(const char *path, char *const argv[], char *const envp[], int input, int output, int error, pid_t *pid) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc) return rc;
    rc = posix_spawnattr_init(&attributes);
    if (rc) { posix_spawn_file_actions_destroy(&actions); return rc; }
    posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO);
    // Dispatch worker threads block signals. Children must not inherit that mask:
    // otherwise shell watchdogs cannot receive SIGTERM and cancellation hangs.
    sigset_t empty, defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setpgroup(&attributes, 0);
    rc = posix_spawn(&*pid, path, &actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return rc;
}
int rb_wait(pid_t pid) {
    int status;
    while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return -1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
