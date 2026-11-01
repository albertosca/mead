/*
 * Native code mead needs where Erlang's file API falls short. Built on macOS only.
 *
 * full_fsync/1: on Darwin, :file.sync/1 calls fcntl(F_BARRIERFSYNC), which keeps writes in
 * order but does not ask the drive to flush its cache, so a power cut can lose writes it
 * acknowledged. F_FULLFSYNC does flush it. The flush covers the whole file, not the descriptor,
 * so the path is opened again here instead of reaching into an Erlang file device.
 */

#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#ifndef F_FULLFSYNC
#error "F_FULLFSYNC is not defined: this file is only built on macOS"
#endif

static ERL_NIF_TERM make_error(ErlNifEnv *environment, int error_number) {
    const char *name;

    switch (error_number) {
    case EACCES: name = "eacces"; break;
    case EBADF: name = "ebadf"; break;
    case EINTR: name = "eintr"; break;
    case EINVAL: name = "einval"; break;
    case EIO: name = "eio"; break;
    case ELOOP: name = "eloop"; break;
    case EMFILE: name = "emfile"; break;
    case ENAMETOOLONG: name = "enametoolong"; break;
    case ENFILE: name = "enfile"; break;
    case ENOENT: name = "enoent"; break;
    case ENOMEM: name = "enomem"; break;
    case ENOSPC: name = "enospc"; break;
    case ENOTDIR: name = "enotdir"; break;
    case EPERM: name = "eperm"; break;
    case EROFS: name = "erofs"; break;
    default:
        return enif_make_tuple2(
            environment, enif_make_atom(environment, "error"),
            enif_make_tuple2(environment, enif_make_atom(environment, "errno"),
                             enif_make_int(environment, error_number)));
    }

    return enif_make_tuple2(environment, enif_make_atom(environment, "error"),
                            enif_make_atom(environment, name));
}

/* A file system that has no F_FULLFSYNC (some network and FUSE volumes) answers one of these;
 * fsync is then the most it can do, which is what SQLite does too. */
static int unsupported(int error_number) {
    return error_number == ENOTSUP || error_number == EINVAL || error_number == ENOTTY;
}

static int flush_descriptor(int descriptor) {
    int result;

    do {
        result = fcntl(descriptor, F_FULLFSYNC);
    } while (result != 0 && errno == EINTR);

    if (result != 0 && unsupported(errno)) {
        do {
            result = fsync(descriptor);
        } while (result != 0 && errno == EINTR);
    }

    return result;
}

static ERL_NIF_TERM full_fsync(ErlNifEnv *environment, int argument_count,
                               const ERL_NIF_TERM arguments[]) {
    ErlNifBinary path;
    char *terminated;
    int descriptor;
    int result;
    int error_number;

    if (argument_count != 1 || !enif_inspect_binary(environment, arguments[0], &path)) {
        return enif_make_badarg(environment);
    }

    if (memchr(path.data, 0, path.size) != NULL) {
        return make_error(environment, EINVAL);
    }

    terminated = enif_alloc(path.size + 1);
    if (terminated == NULL) {
        return make_error(environment, ENOMEM);
    }

    memcpy(terminated, path.data, path.size);
    terminated[path.size] = '\0';

    do {
        descriptor = open(terminated, O_RDONLY | O_CLOEXEC);
    } while (descriptor < 0 && errno == EINTR);

    error_number = errno;
    enif_free(terminated);

    if (descriptor < 0) {
        return make_error(environment, error_number);
    }

    result = flush_descriptor(descriptor);
    error_number = errno;
    close(descriptor);

    if (result != 0) {
        return make_error(environment, error_number);
    }

    return enif_make_atom(environment, "ok");
}

static ErlNifFunc functions[] = {
    {"full_fsync", 1, full_fsync, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Mead.Native, functions, NULL, NULL, NULL, NULL)
