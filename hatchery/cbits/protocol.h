#ifndef HATCHERY_PROTOCOL_H
#define HATCHERY_PROTOCOL_H

#include <stdint.h>

/* Commands: Haskell -> fork server */
enum cmd_type {
    CMD_DISPATCH  = 1,
    CMD_STATUS    = 2,
    CMD_SHUTDOWN  = 3,
    CMD_RUN       = 4,  /* re-run pre-loaded code on a specific worker */
    CMD_RESERVE   = 5,  /* reserve an idle worker (returns worker_id) */
    CMD_RELEASE   = 6,  /* release a reserved worker back to the pool */
};

struct cmd_dispatch {
    uint32_t worker_id;
    uint32_t injection_method;  /* enum injection_method from ring_buffer.h */
    uint32_t code_len;
    /* code bytes follow immediately after this struct when sent over socketpair */
};

struct cmd_run {
    uint32_t worker_id;
};

struct cmd_reserve_release {
    uint32_t worker_id;  /* -1 for auto-select (reserve), specific id (release) */
};

struct command {
    uint32_t type;  /* enum cmd_type */
    union {
        struct cmd_dispatch dispatch;
        struct cmd_run run;
        struct cmd_reserve_release reserve_release;
    };
};

/* Responses: fork server -> Haskell */
enum rsp_type {
    RSP_WORKER_READY   = 1,
    RSP_WORKER_DONE    = 2,
    RSP_WORKER_CRASHED = 3,
    RSP_POOL_STATUS    = 4,
    RSP_ERROR          = 5,
    RSP_WORKER_RESERVED = 6,
};

struct rsp_worker_done {
    uint32_t worker_id;
    int32_t  exit_code;
    uint32_t result_size;
    /* result bytes follow if result_size > 0 */
};

struct rsp_worker_crashed {
    uint32_t worker_id;
    int32_t  signal;
};

struct rsp_pool_status {
    uint32_t pool_size;
    uint32_t idle_count;
    uint32_t busy_count;
    uint32_t crashed_count;
};

struct response {
    uint32_t type;  /* enum rsp_type */
    union {
        struct { uint32_t worker_id; } worker_ready;
        struct rsp_worker_done worker_done;
        struct rsp_worker_crashed worker_crashed;
        struct rsp_pool_status pool_status;
        struct { int32_t code; } error;
        struct { uint32_t worker_id; } worker_reserved;
    };
};

#endif /* HATCHERY_PROTOCOL_H */
