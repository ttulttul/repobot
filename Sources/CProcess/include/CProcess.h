#ifndef REPOBOT_PROCESS_H
#define REPOBOT_PROCESS_H
#include <sys/types.h>
// Each command receives its own process group, allowing timeout/cancel to reap descendants.
int rb_spawn(const char *path, char *const argv[], char *const envp[], int input, int output, int error, pid_t *pid);
int rb_wait(pid_t pid);
#endif
