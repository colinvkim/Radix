#include <sys/attr.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <execinfo.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Audit-only libc entry-point counts. Run separately from timing samples:
// descriptor filtering adds F_GETPATH calls and is deliberately not timed.
static const char *root;
static size_t root_length;
enum { BULK, BULK_ENTRIES, ATTR, LSTAT, STAT, FSTAT, FSTATAT, COUNT };
static _Atomic unsigned long long counts[COUNT];
__attribute__((constructor)) static void begin(void) {
    root = getenv("RADIX_AUDIT_COUNT_PATH");
    root_length = root ? strlen(root) : 0;
}
static int includes(const char *path) {
    if (path && strncmp(path, "/.nofollow/", 11) == 0) path += 10;
    if (path && strncmp(path, "/.resolve/", 10) == 0) path += 9;
    if (!root || !path) return 0;
    if (strncmp(root, path, root_length) == 0
        && (path[root_length] == '/' || path[root_length] == '\0')) return 1;
    // Foundation may shorten /private/tmp to /tmp in filesystem representations.
    return strncmp(root, "/private/tmp/", 13) == 0
        && strncmp(root + 8, path, root_length - 8) == 0
        && (path[root_length - 8] == '/' || path[root_length - 8] == '\0');
}
static int includes_fd(int fd) {
    char path[4096];
    int saved_errno = errno;
    int result = root && fcntl(fd, F_GETPATH, path) == 0 && includes(path);
    errno = saved_errno;
    return result;
}
static int audit_bulk(int fd, struct attrlist *attrs, void *buffer, size_t size, uint64_t options) {
    int result = getattrlistbulk(fd, attrs, buffer, size, options);
    if (includes_fd(fd)) {
        atomic_fetch_add(&counts[BULK], 1);
        if (result > 0) atomic_fetch_add(&counts[BULK_ENTRIES], result);
    }
    return result;
}
static int audit_attr(const char *path, struct attrlist *attrs, void *buffer, size_t size, unsigned long options) {
    if (includes(path)) atomic_fetch_add(&counts[ATTR], 1);
    return getattrlist(path, attrs, buffer, size, options);
}
static int audit_lstat(const char *path, struct stat *status) {
    static _Atomic int stack_count;
    if (getenv("RADIX_AUDIT_STACKS") && path && includes(path)
        && strstr(path, "file-00000000.dat") && atomic_fetch_add(&stack_count, 1) < 2) {
        void *frames[12];
        fprintf(stderr, "RADIX_AUDIT_LSTAT_STACK\n");
        backtrace_symbols_fd(frames, backtrace(frames, 12), 2);
    }
    if (includes(path)) atomic_fetch_add(&counts[LSTAT], 1);
    return lstat(path, status);
}
static int audit_stat(const char *path, struct stat *status) {
    if (includes(path)) atomic_fetch_add(&counts[STAT], 1);
    return stat(path, status);
}
static int audit_fstat(int fd, struct stat *status) {
    if (includes_fd(fd)) atomic_fetch_add(&counts[FSTAT], 1);
    return fstat(fd, status);
}
static int audit_fstatat(int fd, const char *path, struct stat *status, int flags) {
    if (includes(path) || (path && path[0] != '/' && includes_fd(fd)))
        atomic_fetch_add(&counts[FSTATAT], 1);
    return fstatat(fd, path, status, flags);
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replace; const void *original; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(replacement), (const void *)(original) };
INTERPOSE(audit_bulk, getattrlistbulk)
INTERPOSE(audit_attr, getattrlist)
INTERPOSE(audit_lstat, lstat)
INTERPOSE(audit_stat, stat)
INTERPOSE(audit_fstat, fstat)
INTERPOSE(audit_fstatat, fstatat)
__attribute__((destructor)) static void finish(void) {
    if (!root) return;
    fprintf(stderr, "RADIX_AUDIT_LIBC_COUNTS bulk=%llu bulk_entries=%llu getattrlist=%llu lstat=%llu stat=%llu fstat=%llu fstatat=%llu\n",
        counts[BULK], counts[BULK_ENTRIES], counts[ATTR], counts[LSTAT], counts[STAT], counts[FSTAT], counts[FSTATAT]);
}
