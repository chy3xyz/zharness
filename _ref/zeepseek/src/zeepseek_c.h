#include <dirent.h>
#include <sandbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

// Explicit declarations for translateC
extern FILE *popen(const char *command, const char *type);
extern int pclose(FILE *stream);
