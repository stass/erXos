/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The NIF of erx_net's tap transport (portable/erx_tap.erl, loaded by
 * portable/erx_tap_nif.erl; docs/design-network-stack.md, "The tap
 * transport"): Ethernet frames exchanged with a host's tap device, one frame
 * per read(2) and per writev(2), the kernel's copy the only copy of a frame's
 * bytes.  c_src/Makefile builds it on the host it runs on into
 * priv/erx_tap_nif.so; it is never built for erXos.
 *
 * The handle is a resource holding the descriptor.  It monitors the process
 * that opened it, its owner, and every call from another process is badarg,
 * so the handle has one user and no lock.  The descriptor is closed only
 * once the owner has ended: at once when it was never armed, else from the
 * stop callback once ERTS's poll set has let go of it, so no call ever meets
 * a descriptor number the process has reused.
 *
 * Each call does a bounded amount of work on a normal scheduler: recv/1 at
 * most 64 reads or 64 KiB, send/2 one frame of at most the MTU, which its
 * caller has checked before handing it over.  No thread waits: an empty
 * device is armed for reading, and a full one for writing, with
 * enif_select, whose message is the transport's wake.
 *
 * Frames are untrusted.  No byte of one is read here: a received frame's
 * length, which read(2) returns, is the one value taken from the device,
 * checked against the buffer before it is used.
 */

#define _POSIX_C_SOURCE	200809L

#include <sys/types.h>
#include <sys/uio.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

#include "erl_nif.h"

#define ERX_TAP_ETHER_HDR_LEN	14
#define ERX_TAP_MTU_MIN		68
#define ERX_TAP_MTU_MAX		9000
/* One recv/1 call reads at most this many frames, or this many bytes. */
#define ERX_TAP_RECV_FRAMES	64
#define ERX_TAP_RECV_BYTES	65536
/* A frame handed as more binaries than this is joined before it is written. */
#define ERX_TAP_IOV_MAX		64
/* The most writes of one frame that EINTR interrupts before send/2 gives up. */
#define ERX_TAP_WRITE_TRIES	8
/* The walk of a frame's iodata gives up, and joins it, past these. */
#define ERX_TAP_WALK_DEPTH	8
#define ERX_TAP_WALK_CELLS	256

typedef struct erx_tap {
	int		fd;		/* -1 once closed */
	bool		selected;	/* ever handed to enif_select */
	unsigned	mtu;
	ErlNifPid	owner;
	ErlNifMonitor	monitor;
} erx_tap_t;

/* What one read(2) of the device made: the decision core of recv/1. */
typedef enum erx_tap_read_kind {
	ERX_TAP_READ_FRAME,	/* a frame to keep */
	ERX_TAP_READ_MALFORMED,	/* shorter than the Ethernet header */
	ERX_TAP_READ_TOO_LONG,	/* filled the buffer: longer than the MTU allows */
	ERX_TAP_READ_EMPTY,	/* EAGAIN: no frame waits */
	ERX_TAP_READ_AGAIN,	/* EINTR: read again */
	ERX_TAP_READ_EOF,	/* end of file: the device is gone */
	ERX_TAP_READ_FAILED	/* any other error */
} erx_tap_read_kind_t;

/* What ended a recv/1 batch. */
typedef enum erx_tap_batch_end {
	ERX_TAP_END_BOUND,	/* a bound: frames may wait, answer more */
	ERX_TAP_END_EMPTY,	/* no frame left: arm, answer armed */
	ERX_TAP_END_EOF,	/* the device is gone */
	ERX_TAP_END_FAILED,	/* a read failed */
	ERX_TAP_END_NOMEM	/* no binary for the next frame */
} erx_tap_batch_end_t;

/* What one writev(2) of a frame made: the decision core of send/2. */
typedef enum erx_tap_write_kind {
	ERX_TAP_WRITE_TAKEN,	/* the whole frame */
	ERX_TAP_WRITE_REFUSED,	/* none of it, or ENOBUFS: the tap discarded it */
	ERX_TAP_WRITE_FULL,	/* EAGAIN: arm for writing */
	ERX_TAP_WRITE_AGAIN,	/* EINTR: write again */
	ERX_TAP_WRITE_PARTIAL,	/* part of it: the medium is broken */
	ERX_TAP_WRITE_FAILED	/* any other error */
} erx_tap_write_kind_t;

/* How a frame's iodata is handed to writev(2). */
typedef enum erx_tap_walk {
	ERX_TAP_WALK_IOV,	/* its binaries, each one iovec */
	ERX_TAP_WALK_JOIN,	/* joined first: too many pieces, or byte integers */
	ERX_TAP_WALK_BADARG	/* not iodata */
} erx_tap_walk_t;

static ErlNifResourceType *erx_tap_type;

static ERL_NIF_TERM atom_armed, atom_drop, atom_eof, atom_error, atom_erx_tap,
    atom_full, atom_malformed, atom_more, atom_ok, atom_partial, atom_readable,
    atom_refused, atom_too_long, atom_undefined, atom_writable;

/* --- The decision core ------------------------------------------------- */

/*
 * A read into a buffer of cap bytes, cap the MTU, the Ethernet header and
 * one byte more, so that a frame which fills it is longer than allowed.
 */
static erx_tap_read_kind_t
erx_tap_read_kind(ssize_t n, int error, size_t cap)
{

	if (n < 0) {
		if (error == EINTR)
			return (ERX_TAP_READ_AGAIN);
		if (error == EAGAIN || error == EWOULDBLOCK)
			return (ERX_TAP_READ_EMPTY);
		return (ERX_TAP_READ_FAILED);
	}
	if (n == 0)
		return (ERX_TAP_READ_EOF);
	if ((size_t)n < ERX_TAP_ETHER_HDR_LEN)
		return (ERX_TAP_READ_MALFORMED);
	if ((size_t)n >= cap)
		return (ERX_TAP_READ_TOO_LONG);
	return (ERX_TAP_READ_FRAME);
}

/*
 * A write of a frame of len bytes.  A tap discards a frame as a wire loses
 * one: FreeBSD's tunwrite takes none of it while the interface is down, and
 * a kernel short of buffers answers ENOBUFS.
 */
static erx_tap_write_kind_t
erx_tap_write_kind(ssize_t n, int error, size_t len)
{

	if (n < 0) {
		if (error == EINTR)
			return (ERX_TAP_WRITE_AGAIN);
		if (error == EAGAIN || error == EWOULDBLOCK)
			return (ERX_TAP_WRITE_FULL);
		if (error == ENOBUFS)
			return (ERX_TAP_WRITE_REFUSED);
		return (ERX_TAP_WRITE_FAILED);
	}
	if (n == 0)
		return (ERX_TAP_WRITE_REFUSED);
	if ((size_t)n == len)
		return (ERX_TAP_WRITE_TAKEN);
	return (ERX_TAP_WRITE_PARTIAL);
}

/*
 * Collects the binaries of the frame's iodata into iov, without recursion
 * and within fixed bounds, and their total size into *len.  Anything but
 * binaries and lists of them, or more than the bounds allow, is joined by
 * the caller instead; a term that is not iodata at all is badarg.
 */
static erx_tap_walk_t
erx_tap_walk(ErlNifEnv *env, ERL_NIF_TERM frame, struct iovec *iov,
    int *niov, size_t *len)
{
	ERL_NIF_TERM tails[ERX_TAP_WALK_DEPTH];
	ERL_NIF_TERM cur, head, tail;
	ErlNifBinary bin;
	int depth, cells;

	*niov = 0;
	*len = 0;
	depth = 0;
	cur = frame;
	for (cells = 0; cells < ERX_TAP_WALK_CELLS; cells++) {
		if (enif_inspect_binary(env, cur, &bin)) {
			if (*niov == ERX_TAP_IOV_MAX)
				return (ERX_TAP_WALK_JOIN);
			if (bin.size > 0) {
				iov[*niov].iov_base = bin.data;
				iov[*niov].iov_len = bin.size;
				(*niov)++;
				*len += bin.size;
			}
		} else if (enif_get_list_cell(env, cur, &head, &tail)) {
			if (depth == ERX_TAP_WALK_DEPTH)
				return (ERX_TAP_WALK_JOIN);
			tails[depth++] = tail;
			cur = head;
			continue;
		} else if (enif_is_number(env, cur)) {
			return (ERX_TAP_WALK_JOIN);
		} else if (!enif_is_empty_list(env, cur)) {
			return (ERX_TAP_WALK_BADARG);
		}
		/* cur is done: go on with the innermost tail left. */
		if (depth == 0)
			return (ERX_TAP_WALK_IOV);
		cur = tails[--depth];
	}
	return (ERX_TAP_WALK_JOIN);
}

/* --- Terms -------------------------------------------------------------- */

/* An error number as an atom where it has a usual name, else as an integer. */
static ERL_NIF_TERM
erx_tap_errno(ErlNifEnv *env, int error)
{
	static const struct {
		int		 error;
		const char	*name;
	} names[] = {
		{ EACCES, "eacces" }, { EBADF, "ebadf" }, { EBUSY, "ebusy" },
		{ EFAULT, "efault" }, { EINVAL, "einval" }, { EIO, "eio" },
		{ EISDIR, "eisdir" }, { EMSGSIZE, "emsgsize" },
		{ ENOENT, "enoent" }, { ENOMEM, "enomem" }, { ENODEV, "enodev" },
		{ ENOTDIR, "enotdir" }, { ENXIO, "enxio" }, { EPERM, "eperm" },
		{ ECONNRESET, "econnreset" }, { ENOTCONN, "enotconn" },
		{ EPIPE, "epipe" },
	};
	size_t i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		if (names[i].error == error)
			return (enif_make_atom(env, names[i].name));
	return (enif_make_int(env, error));
}

/* {error, {Step, Errno}} */
static ERL_NIF_TERM
erx_tap_failed(ErlNifEnv *env, const char *step, int error)
{

	return (enif_make_tuple2(env, atom_error, enif_make_tuple2(env,
	    enif_make_atom(env, step), erx_tap_errno(env, error))));
}

static ERL_NIF_TERM
erx_tap_drop(ErlNifEnv *env, ERL_NIF_TERM reason)
{

	return (enif_make_tuple2(env, atom_drop, reason));
}

/* The handle of argv[0], when the caller is its owner; NULL otherwise. */
static erx_tap_t *
erx_tap_handle(ErlNifEnv *env, ERL_NIF_TERM term)
{
	erx_tap_t *tap;
	ErlNifPid self;

	if (!enif_get_resource(env, term, erx_tap_type, (void **)&tap))
		return (NULL);
	if (enif_self(env, &self) == NULL ||
	    enif_compare_pids(&self, &tap->owner) != 0 || tap->fd < 0)
		return (NULL);
	return (tap);
}

/* Arms the descriptor for one direction; its message is {erx_tap, Which}. */
static bool
erx_tap_arm(ErlNifEnv *env, erx_tap_t *tap, bool reading)
{
	ERL_NIF_TERM msg;
	int r;

	msg = enif_make_tuple2(env, atom_erx_tap,
	    reading ? atom_readable : atom_writable);
	tap->selected = true;
	if (reading)
		r = enif_select_read(env, tap->fd, tap, &tap->owner, msg, NULL);
	else
		r = enif_select_write(env, tap->fd, tap, &tap->owner, msg, NULL);
	return (r >= 0);
}

/* --- The calls ---------------------------------------------------------- */

/*
 * open(Path, Mtu) -> {ok, Handle} | {error, {open, Errno}}: the device read
 * and write, non-blocking and close-on-exec, owned by the caller.
 */
static ERL_NIF_TERM
erx_tap_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	char path[PATH_MAX];
	ErlNifBinary name;
	ERL_NIF_TERM handle;
	erx_tap_t *tap;
	unsigned mtu;
	int fd;

	(void)argc;
	if (!enif_inspect_binary(env, argv[0], &name) || name.size == 0 ||
	    name.size >= sizeof(path) || memchr(name.data, 0, name.size) != NULL ||
	    !enif_get_uint(env, argv[1], &mtu) || mtu < ERX_TAP_MTU_MIN ||
	    mtu > ERX_TAP_MTU_MAX)
		return (enif_make_badarg(env));
	memcpy(path, name.data, name.size);
	path[name.size] = '\0';

	do
		fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	while (fd < 0 && errno == EINTR);
	if (fd < 0)
		return (erx_tap_failed(env, "open", errno));

	tap = enif_alloc_resource(erx_tap_type, sizeof(*tap));
	if (tap == NULL) {
		(void)close(fd);
		return (erx_tap_failed(env, "open", ENOMEM));
	}
	tap->fd = fd;
	tap->selected = false;
	tap->mtu = mtu;
	if (enif_self(env, &tap->owner) == NULL ||
	    enif_monitor_process(env, tap, &tap->owner, &tap->monitor) != 0) {
		/* The owner is gone, or no monitor: the destructor closes. */
		enif_release_resource(tap);
		return (enif_make_badarg(env));
	}
	handle = enif_make_resource(env, tap);
	enif_release_resource(tap);
	return (enif_make_tuple2(env, atom_ok, handle));
}

/*
 * recv(Handle) -> {ok, Frames, Drops, more | armed} | {error, Reason}: the
 * frames waiting, each read into a binary of its own, up to the bounds.
 * Drops counts the frames dropped by reason.  armed: the device had no
 * frame left and is armed for reading; more: a bound was reached.
 */
static ERL_NIF_TERM
erx_tap_recv(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM frames[ERX_TAP_RECV_FRAMES];
	ERL_NIF_TERM drops;
	ErlNifBinary bin;
	erx_tap_batch_end_t end;
	erx_tap_t *tap;
	size_t cap, bytes, malformed, too_long;
	ssize_t n;
	bool have;
	int error, reads, kept, pct;

	(void)argc;
	if ((tap = erx_tap_handle(env, argv[0])) == NULL)
		return (enif_make_badarg(env));
	cap = (size_t)tap->mtu + ERX_TAP_ETHER_HDR_LEN + 1;
	bytes = malformed = too_long = 0;
	kept = error = 0;
	have = false;
	end = ERX_TAP_END_BOUND;
	memset(&bin, 0, sizeof(bin));

	/*
	 * Each pass is one read, an interrupted one included, into the buffer
	 * bin when have is set; a frame kept takes the buffer with it.
	 */
	for (reads = 0; end == ERX_TAP_END_BOUND &&
	    reads < ERX_TAP_RECV_FRAMES && bytes < ERX_TAP_RECV_BYTES; reads++) {
		if (!have && !enif_alloc_binary(cap, &bin)) {
			end = ERX_TAP_END_NOMEM;
			break;
		}
		have = true;
		n = read(tap->fd, bin.data, cap);
		error = errno;
		switch (erx_tap_read_kind(n, error, cap)) {
		case ERX_TAP_READ_AGAIN:
			break;
		case ERX_TAP_READ_EMPTY:
			end = ERX_TAP_END_EMPTY;
			break;
		case ERX_TAP_READ_EOF:
			end = ERX_TAP_END_EOF;
			break;
		case ERX_TAP_READ_FAILED:
			end = ERX_TAP_END_FAILED;
			break;
		case ERX_TAP_READ_MALFORMED:
			malformed++;
			bytes += (size_t)n;
			break;
		case ERX_TAP_READ_TOO_LONG:
			too_long++;
			bytes += (size_t)n;
			break;
		case ERX_TAP_READ_FRAME:
			/* Cut to the frame, so no unwritten byte is handed up. */
			if (!enif_realloc_binary(&bin, (size_t)n)) {
				end = ERX_TAP_END_NOMEM;
				break;
			}
			frames[kept++] = enif_make_binary(env, &bin);
			have = false;
			bytes += (size_t)n;
			break;
		}
	}
	if (have)
		enif_release_binary(&bin);

	/*
	 * 1 percent of a slice is about 10 us: a read costs about 1 us, and
	 * 64 KiB of the kernel's copy about 10.
	 */
	pct = 1 + reads / 8 + (int)(bytes / 65536);
	(void)enif_consume_timeslice(env, pct > 100 ? 100 : pct);

	switch (end) {
	case ERX_TAP_END_BOUND:
		break;
	case ERX_TAP_END_EMPTY:
		if (!erx_tap_arm(env, tap, true))
			return (enif_make_tuple2(env, atom_error,
			    enif_make_atom(env, "arm")));
		break;
	case ERX_TAP_END_EOF:
		return (enif_make_tuple2(env, atom_error, atom_eof));
	case ERX_TAP_END_FAILED:
		return (erx_tap_failed(env, "read", error));
	case ERX_TAP_END_NOMEM:
		return (erx_tap_failed(env, "read", ENOMEM));
	}
	drops = enif_make_new_map(env);
	if (malformed > 0)
		(void)enif_make_map_put(env, drops, atom_malformed,
		    enif_make_uint64(env, malformed), &drops);
	if (too_long > 0)
		(void)enif_make_map_put(env, drops, atom_too_long,
		    enif_make_uint64(env, too_long), &drops);
	return (enif_make_tuple4(env, atom_ok,
	    enif_make_list_from_array(env, frames, (unsigned)kept), drops,
	    end == ERX_TAP_END_EMPTY ? atom_armed : atom_more));
}

/*
 * send(Handle, Frame) -> {ok, 1} | full | {drop, Reason} | {error, Reason}:
 * one frame, iodata, handed to the kernel in one writev(2) of its binaries.
 * full: none of it was taken, and the device is armed for writing.
 */
static ERL_NIF_TERM
erx_tap_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	struct iovec iov[ERX_TAP_IOV_MAX];
	ErlNifBinary joined;
	erx_tap_t *tap;
	size_t len;
	ssize_t n;
	int niov, tries;

	(void)argc;
	if ((tap = erx_tap_handle(env, argv[0])) == NULL)
		return (enif_make_badarg(env));
	switch (erx_tap_walk(env, argv[1], iov, &niov, &len)) {
	case ERX_TAP_WALK_IOV:
		break;
	case ERX_TAP_WALK_JOIN:
		if (!enif_inspect_iolist_as_binary(env, argv[1], &joined))
			return (enif_make_badarg(env));
		iov[0].iov_base = joined.data;
		iov[0].iov_len = joined.size;
		niov = 1;
		len = joined.size;
		break;
	case ERX_TAP_WALK_BADARG:
		return (enif_make_badarg(env));
	}
	if (len < ERX_TAP_ETHER_HDR_LEN)
		return (erx_tap_drop(env, atom_malformed));
	if (len > (size_t)tap->mtu + ERX_TAP_ETHER_HDR_LEN)
		return (erx_tap_drop(env, atom_too_long));

	/* An interrupted write is tried again, a few times at the most. */
	for (tries = 0; tries < ERX_TAP_WRITE_TRIES; tries++) {
		n = writev(tap->fd, iov, niov);
		switch (erx_tap_write_kind(n, errno, len)) {
		case ERX_TAP_WRITE_AGAIN:
			continue;
		case ERX_TAP_WRITE_TAKEN:
			return (enif_make_tuple2(env, atom_ok,
			    enif_make_int(env, 1)));
		case ERX_TAP_WRITE_REFUSED:
			return (erx_tap_drop(env, atom_refused));
		case ERX_TAP_WRITE_FULL:
			if (!erx_tap_arm(env, tap, false))
				return (enif_make_tuple2(env, atom_error,
				    enif_make_atom(env, "arm")));
			return (atom_full);
		case ERX_TAP_WRITE_PARTIAL:
			return (enif_make_tuple2(env, atom_error,
			    atom_partial));
		case ERX_TAP_WRITE_FAILED:
			return (erx_tap_failed(env, "write", errno));
		}
	}
	return (erx_tap_failed(env, "write", EINTR));
}

/* --- The handle's life -------------------------------------------------- */

/* The poll set has let go of the descriptor: close it. */
static void
erx_tap_stop(ErlNifEnv *env, void *obj, ErlNifEvent event, int direct)
{
	erx_tap_t *tap = obj;

	(void)env;
	(void)direct;
	(void)close((int)event);
	tap->fd = -1;
}

/*
 * The owner ended, so no call can come: close the descriptor at once when
 * it was never armed, else once ERTS's poll set has let go of it.
 */
static void
erx_tap_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
	erx_tap_t *tap = obj;
	int r;

	(void)pid;
	(void)mon;
	if (tap->fd < 0)
		return;
	if (tap->selected) {
		r = enif_select(env, tap->fd, ERL_NIF_SELECT_STOP, tap, NULL,
		    atom_undefined);
		if (r >= 0)
			return;
		/* ERTS does not know the descriptor: nothing polls it. */
	}
	(void)close(tap->fd);
	tap->fd = -1;
}

/*
 * The last reference is gone.  An armed descriptor keeps its handle alive
 * until the stop callback, so one still open here was never armed.
 */
static void
erx_tap_dtor(ErlNifEnv *env, void *obj)
{
	erx_tap_t *tap = obj;

	(void)env;
	if (tap->fd >= 0)
		(void)close(tap->fd);
}

static int
erx_tap_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	ErlNifResourceTypeInit init = {
		.dtor = erx_tap_dtor,
		.stop = erx_tap_stop,
		.down = erx_tap_down,
	};

	(void)priv;
	(void)info;
	erx_tap_type = enif_open_resource_type_x(env, "erx_tap", &init,
	    ERL_NIF_RT_CREATE, NULL);
	if (erx_tap_type == NULL)
		return (1);
	atom_armed = enif_make_atom(env, "armed");
	atom_drop = enif_make_atom(env, "drop");
	atom_eof = enif_make_atom(env, "eof");
	atom_error = enif_make_atom(env, "error");
	atom_erx_tap = enif_make_atom(env, "erx_tap");
	atom_full = enif_make_atom(env, "full");
	atom_malformed = enif_make_atom(env, "malformed");
	atom_more = enif_make_atom(env, "more");
	atom_ok = enif_make_atom(env, "ok");
	atom_partial = enif_make_atom(env, "partial");
	atom_readable = enif_make_atom(env, "readable");
	atom_refused = enif_make_atom(env, "refused");
	atom_too_long = enif_make_atom(env, "too_long");
	atom_undefined = enif_make_atom(env, "undefined");
	atom_writable = enif_make_atom(env, "writable");
	return (0);
}

static ErlNifFunc nif_funcs[] = {
	{ "open", 2, erx_tap_open, 0 },
	{ "recv", 1, erx_tap_recv, 0 },
	{ "send", 2, erx_tap_send, 0 },
};

ERL_NIF_INIT(erx_tap_nif, nif_funcs, erx_tap_load, NULL, NULL, NULL)
