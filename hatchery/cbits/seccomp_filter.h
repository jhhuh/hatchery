#ifndef HATCHERY_SECCOMP_FILTER_H
#define HATCHERY_SECCOMP_FILTER_H

/* Install the worker seccomp filter. Returns 0 on success, -1 on failure. */
int install_seccomp_filter(void);

#endif
