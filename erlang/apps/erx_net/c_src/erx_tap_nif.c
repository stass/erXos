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
 * A handle comes from open/2, which opens the device by name, or from
 * adopt/2, which takes a copy of a descriptor its caller already holds, such
 * as one a privileged opener handed over; the caller keeps its own.
 *
 * The handle is a resource holding the descriptor.  It monitors the process
 * that opened it, its owner, and every call from another process is badarg,
 * so the handle has one user and no lock.  The descriptor is closed only
 * once the owner has ended: at once when it was never armed, else from the
 * stop callback once ERTS's poll set has let go of it, so no call ever meets
 * a descriptor number the process has reused.
 *
 * Each call does a bounded amount of work on a normal scheduler: recv/1 at
 * most 64 reads or 64 KiB, send/2 one frame of at most the MTU, or at most
 * 64 frames of a run, each one writev(2).  No thread waits: an empty
 * device is armed for reading, and a full one for writing, with
 * enif_select, whose message is the transport's wake.
 *
 * Frames are untrusted.  None is parsed here: a received frame's length,
 * which read(2) returns, is the one value taken from the device, checked
 * against the buffer before it is used.  Each received frame is handed up
 * with its network sum, the Internet checksum sum of its bytes after the
 * Ethernet header (erx_inet_csum.c), taken right after the read while the
 * bytes are in the cache, so no Erlang process reads them to check a
 * checksum (docs/design-network-stack.md, "Checksums in the copy").  The
 * sum is a sum of whatever bytes the frame holds, never a verdict.  A sent
 * frame whose TCP checksum the stack delayed is finished in send/2's writev(2):
 * its sum is taken over the frame's binaries where they lie, and its checksum
 * field is written from an iovec of its own (erx_tap_finish).  A run, the
 * frames of a TCP run over one header template (erx_net_frame.hrl's #run{}),
 * is cut by erx_tcp_cut.c as send/2 hands it over: each frame's headers are
 * written to a buffer of the NIF's own with the payload slice summed where it
 * lies, and one writev(2) hands the kernel the headers and the slice
 * (docs/design-network-fastpath.md, "The cut, in the copy").
 */

#define _POSIX_C_SOURCE	200809L

#include <sys/types.h>
#include <sys/uio.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "erl_nif.h"

#include "erx_inet_csum.h"
#include "erx_tcp_cut.h"

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
/* One send/2 call writes at most this many frames of a run. */
#define ERX_TAP_RUN_FRAMES	64
/* A run term: {run, Link, Template, Seq, Ack, Flags, Win, Ts, Seg, Payload}. */
#define ERX_TAP_RUN_ARITY	10
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

static ERL_NIF_TERM atom_armed, atom_csum, atom_drop, atom_eof, atom_error,
    atom_erx_tap, atom_full, atom_malformed, atom_more, atom_none, atom_ok,
    atom_partial, atom_readable, atom_refused, atom_run, atom_sum,
    atom_too_long, atom_undefined, atom_writable;

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

/*
 * Finishes the delayed checksum of a frame of len bytes held in the niov
 * pieces of iov (docs/design-network-stack.md, "Checksums in the copy"):
 * field_bytes receives, in network byte order, the complement of the sum of
 * the frame's bytes from start to its end, the field's two bytes at
 * start + field included, and out receives the frame's pieces with those two
 * bytes replaced by field_bytes, so no binary is written.  *nout is out's
 * count: one piece may become three, so at most niov + 2.  False, with
 * nothing written, when start or field is odd or the field does not lie
 * inside the frame; start and field come from the caller's term and are
 * checked here, once, before either is used.
 */
static bool
erx_tap_finish(const struct iovec *iov, int niov, size_t len, size_t start,
    size_t field, uint8_t field_bytes[2], struct iovec *out, int *nout)
{
	const uint8_t *base;
	size_t after_from, at, end, pos, sum_from;
	uint16_t running;
	int i;

	if (start % 2 != 0 || field % 2 != 0 || start > len ||
	    field > len - start || len - start - field < 2)
		return (false);
	at = start + field;
	running = 0;
	*nout = 0;
	for (i = 0, pos = 0; i < niov; i++, pos = end) {
		base = iov[i].iov_base;
		end = pos + iov[i].iov_len;
		/* The piece's bytes at start and after it are summed. */
		if (end > start) {
			sum_from = start > pos ? start - pos : 0;
			running = erx_inet_sum(running, base + sum_from,
			    iov[i].iov_len - sum_from, pos + sum_from - start);
		}
		/* Its bytes before the field, the field, and its bytes after. */
		if (pos < at) {
			out[*nout].iov_base = (void *)base;
			out[*nout].iov_len = (end < at ? end : at) - pos;
			(*nout)++;
		}
		if (pos <= at && at < end) {
			out[*nout].iov_base = field_bytes;
			out[*nout].iov_len = 2;
			(*nout)++;
		}
		if (end > at + 2) {
			after_from = pos > at + 2 ? 0 : at + 2 - pos;
			out[*nout].iov_base = (void *)(base + after_from);
			out[*nout].iov_len = iov[i].iov_len - after_from;
			(*nout)++;
		}
	}
	running = (uint16_t)~running;
	field_bytes[0] = (uint8_t)(running >> 8);
	field_bytes[1] = (uint8_t)(running & 0xff);
	return (true);
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

/* Reads an MTU the handle accepts, 68 to 9,000, from term. */
static bool
erx_tap_get_mtu(ErlNifEnv *env, ERL_NIF_TERM term, unsigned *mtu)
{

	return (enif_get_uint(env, term, mtu) && *mtu >= ERX_TAP_MTU_MIN &&
	    *mtu <= ERX_TAP_MTU_MAX);
}

/*
 * {ok, Handle}: a handle on the descriptor fd, which the calling process
 * owns.  The handle owns fd from here: a failure closes it at once, and
 * success hands it to the resource, which closes it once its owner ends;
 * step is the call a failure names.
 */
static ERL_NIF_TERM
erx_tap_new(ErlNifEnv *env, int fd, unsigned mtu, const char *step)
{
	ERL_NIF_TERM handle;
	erx_tap_t *tap;

	tap = enif_alloc_resource(erx_tap_type, sizeof(*tap));
	if (tap == NULL) {
		(void)close(fd);
		return (erx_tap_failed(env, step, ENOMEM));
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
	unsigned mtu;
	int fd;

	(void)argc;
	if (!enif_inspect_binary(env, argv[0], &name) || name.size == 0 ||
	    name.size >= sizeof(path) || memchr(name.data, 0, name.size) != NULL ||
	    !erx_tap_get_mtu(env, argv[1], &mtu))
		return (enif_make_badarg(env));
	memcpy(path, name.data, name.size);
	path[name.size] = '\0';

	do
		fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	while (fd < 0 && errno == EINTR);
	if (fd < 0)
		return (erx_tap_failed(env, "open", errno));
	return (erx_tap_new(env, fd, mtu, "open"));
}

/*
 * adopt(Fd, Mtu) -> {ok, Handle} | {error, {adopt, Errno}}: a close-on-exec
 * copy of the caller's open descriptor Fd, made non-blocking, owned by the
 * caller.  Fd stays the caller's, and close(2) of it leaves the copy open.
 * The copy shares Fd's open file and so its flags: Fd turns non-blocking too,
 * and the caller keeps it so while the handle lives, since a read or write of
 * a blocking copy would stall the scheduler.  OTP's socket:close/1, for one,
 * makes a socket blocking before it closes it.  A descriptor that is not open
 * is EBADF, from the copy.
 */
static ERL_NIF_TERM
erx_tap_adopt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned mtu;
	int copy, fd, flags;

	(void)argc;
	if (!enif_get_int(env, argv[0], &fd) || fd < 0 ||
	    !erx_tap_get_mtu(env, argv[1], &mtu))
		return (enif_make_badarg(env));

	copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
	if (copy < 0)
		return (erx_tap_failed(env, "adopt", errno));
	flags = fcntl(copy, F_GETFL);
	if (flags < 0 || fcntl(copy, F_SETFL, flags | O_NONBLOCK) < 0) {
		int error = errno;

		(void)close(copy);
		return (erx_tap_failed(env, "adopt", error));
	}
	return (erx_tap_new(env, copy, mtu, "adopt"));
}

/*
 * recv(Handle) -> {ok, Frames, Drops, more | armed} | {error, Reason}: the
 * frames waiting, each read into a binary of its own and handed up as
 * {sum, Sum, Frame} with its network sum, up to the bounds.
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
	uint16_t sum;
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
			sum = erx_inet_sum(0, bin.data + ERX_TAP_ETHER_HDR_LEN,
			    (size_t)n - ERX_TAP_ETHER_HDR_LEN, 0);
			frames[kept++] = enif_make_tuple3(env, atom_sum,
			    enif_make_uint(env, sum), enif_make_binary(env, &bin));
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
 * The parts of a frame term: a delayed frame {csum, Start, Field, Frame} gives
 * its Frame, Start and Field, with *is_delayed set; any other term is the
 * frame itself.  False for a tuple of another shape.
 */
static bool
erx_tap_frame_term(ErlNifEnv *env, ERL_NIF_TERM term, ERL_NIF_TERM *frame,
    bool *is_delayed, unsigned *start, unsigned *field)
{
	const ERL_NIF_TERM *parts;
	int arity;

	*frame = term;
	*is_delayed = enif_get_tuple(env, term, &arity, &parts);
	if (!*is_delayed)
		return (true);
	if (arity != 4 || !enif_is_identical(parts[0], atom_csum) ||
	    !enif_get_uint(env, parts[1], start) ||
	    !enif_get_uint(env, parts[2], field))
		return (false);
	*frame = parts[3];
	return (true);
}

/* {ok, N}: N frames taken. */
static ERL_NIF_TERM
erx_tap_ok(ErlNifEnv *env, uint32_t n)
{

	return (enif_make_tuple2(env, atom_ok, enif_make_uint(env, n)));
}

/*
 * One frame's writev(2) of len bytes, tried again when interrupted, a few
 * times at the most; *error is the errno of the last try.
 */
static erx_tap_write_kind_t
erx_tap_write(erx_tap_t *tap, const struct iovec *iov, int niov, size_t len,
    int *error)
{
	erx_tap_write_kind_t kind;
	ssize_t n;
	int tries;

	for (tries = 0; tries < ERX_TAP_WRITE_TRIES; tries++) {
		n = writev(tap->fd, iov, niov);
		*error = errno;
		if ((kind = erx_tap_write_kind(n, *error, len)) !=
		    ERX_TAP_WRITE_AGAIN)
			return (kind);
	}
	*error = EINTR;
	return (ERX_TAP_WRITE_FAILED);
}

/*
 * The answer for a frame the device did not take, as kind says: full arms
 * the device for writing.
 */
static ERL_NIF_TERM
erx_tap_not_taken(ErlNifEnv *env, erx_tap_t *tap, erx_tap_write_kind_t kind,
    int error)
{

	switch (kind) {
	case ERX_TAP_WRITE_REFUSED:
		return (erx_tap_drop(env, atom_refused));
	case ERX_TAP_WRITE_FULL:
		if (!erx_tap_arm(env, tap, false))
			return (enif_make_tuple2(env, atom_error,
			    enif_make_atom(env, "arm")));
		return (atom_full);
	case ERX_TAP_WRITE_PARTIAL:
		return (enif_make_tuple2(env, atom_error, atom_partial));
	default:
		return (erx_tap_failed(env, "write", error));
	}
}

/*
 * The fields of a run term, {run, Link, Template, Seq, Ack, Flags, Win, Ts,
 * Seg, Payload} (erx_net_frame.hrl's #run{}), in parts, into run, with its
 * payload's binaries in pieces, which has room for ERX_TCP_CUT_PIECES_MAX.
 * Only the term's shape is read here; every length and field width is
 * erx_tcp_cut_plan's to check.  False for a field of another type or a
 * payload of more binaries than pieces holds.
 */
static bool
erx_tap_run_term(ErlNifEnv *env, const ERL_NIF_TERM *parts, erx_tcp_run_t *run,
    erx_tcp_cut_piece_t *pieces)
{
	const ERL_NIF_TERM *ts;
	ERL_NIF_TERM head, tail;
	ErlNifBinary link, headers, piece;
	unsigned seq, ack, flags, win, tsval, tsecr, seg;
	size_t npieces;
	int arity;
	bool has_ts;

	if (!enif_inspect_binary(env, parts[1], &link) ||
	    !enif_inspect_binary(env, parts[2], &headers) ||
	    !enif_get_uint(env, parts[3], &seq) ||
	    !enif_get_uint(env, parts[4], &ack) ||
	    !enif_get_uint(env, parts[5], &flags) ||
	    !enif_get_uint(env, parts[6], &win) ||
	    !enif_get_uint(env, parts[8], &seg))
		return (false);
	has_ts = !enif_is_identical(parts[7], atom_none);
	tsval = tsecr = 0;
	if (has_ts && (!enif_get_tuple(env, parts[7], &arity, &ts) ||
	    arity != 2 || !enif_get_uint(env, ts[0], &tsval) ||
	    !enif_get_uint(env, ts[1], &tsecr)))
		return (false);
	npieces = 0;
	for (tail = parts[9]; enif_get_list_cell(env, tail, &head, &tail);
	    npieces++) {
		if (npieces == ERX_TCP_CUT_PIECES_MAX ||
		    !enif_inspect_binary(env, head, &piece))
			return (false);
		pieces[npieces].data = piece.data;
		pieces[npieces].length = piece.size;
	}
	if (!enif_is_empty_list(env, tail))
		return (false);
	*run = (erx_tcp_run_t){
		.link = link.data,
		.link_length = link.size,
		.headers = headers.data,
		.headers_length = headers.size,
		.seq = seq,
		.ack = ack,
		.flags = flags,
		.win = win,
		.has_ts = has_ts,
		.tsval = tsval,
		.tsecr = tsecr,
		.seg = seg,
		.pieces = pieces,
		.npieces = npieces,
	};
	return (true);
}

/*
 * send(Handle, Run) -> {ok, N} | full | {drop, Reason} |
 * {error, Reason}: the frames of a run, from the first, cut by erx_tcp_cut.c
 * straight into one writev(2) each: the headers from a buffer of the NIF's
 * own, the payload slice from the run's binaries where they lie, so no binary
 * is copied or changed.  {ok, N}, N > 0, for N frames taken: all of them, the
 * first ERX_TAP_RUN_FRAMES of a longer run, or those before the first one not
 * taken, which the transport's next call answers for itself.  A run whose
 * first frame is not taken is answered as a frame is.  {drop, too_long}
 * for a run whose first frame, its longest, is over the MTU; a run
 * erx_tcp_cut_plan refuses, one of more than ERX_TCP_CUT_PIECES_MAX payload
 * binaries among them, is badarg, since only a bug of the stack makes one:
 * output bounds a run's payload (erx_tcp_sndbuf:range/4).
 */
static ERL_NIF_TERM
erx_tap_send_run(ErlNifEnv *env, erx_tap_t *tap, const ERL_NIF_TERM *parts)
{
	erx_tcp_cut_piece_t pieces[ERX_TCP_CUT_PIECES_MAX];
	erx_tcp_cut_piece_t slice[ERX_TCP_CUT_PIECES_MAX];
	struct iovec iov[1 + ERX_TCP_CUT_PIECES_MAX];
	uint8_t headers[ERX_TCP_CUT_HEADER_MAX];
	erx_tcp_cut_plan_t plan;
	erx_tcp_run_t run;
	erx_tap_write_kind_t kind;
	size_t n, p;
	uint32_t frames, i;
	int error;

	if (!erx_tap_run_term(env, parts, &run, pieces) ||
	    !erx_tcp_cut_plan(&run, &plan))
		return (enif_make_badarg(env));
	if (erx_tcp_cut_length(&plan, 0) >
	    (size_t)tap->mtu + ERX_TAP_ETHER_HDR_LEN)
		return (erx_tap_drop(env, atom_too_long));
	frames = plan.frames < ERX_TAP_RUN_FRAMES ? plan.frames :
	    ERX_TAP_RUN_FRAMES;
	for (i = 0; i < frames; i++) {
		iov[0].iov_base = headers;
		iov[0].iov_len = erx_tcp_cut_header(&plan, i, headers,
		    sizeof(headers));
		n = erx_tcp_cut_slice(&plan, i, slice);
		for (p = 0; p < n; p++) {
			iov[1 + p].iov_base = (void *)slice[p].data;
			iov[1 + p].iov_len = slice[p].length;
		}
		kind = erx_tap_write(tap, iov, (int)(1 + n),
		    erx_tcp_cut_length(&plan, i), &error);
		if (kind != ERX_TAP_WRITE_TAKEN)
			return (i == 0 ? erx_tap_not_taken(env, tap, kind,
			    error) : erx_tap_ok(env, i));
	}
	return (erx_tap_ok(env, frames));
}

/*
 * send(Handle, Frame) -> {ok, 1} | full | {drop, Reason} | {error, Reason}:
 * one frame, iodata, handed to the kernel in one writev(2) of its binaries.
 * A delayed frame, {csum, Start, Field, Frame}, is handed over with its
 * checksum finished (erx_tap_finish); offsets that do not fit the frame are
 * badarg, since the transport drops such a frame before it calls.  full: none
 * of it was taken, and the device is armed for writing.  A run goes to
 * erx_tap_send_run.
 */
static ERL_NIF_TERM
erx_tap_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	struct iovec iov[ERX_TAP_IOV_MAX], finished[ERX_TAP_IOV_MAX + 2];
	ERL_NIF_TERM frame;
	ErlNifBinary joined;
	const ERL_NIF_TERM *parts;
	struct iovec *write_iov;
	erx_tap_t *tap;
	erx_tap_write_kind_t kind;
	size_t len;
	unsigned start, field;
	uint8_t field_bytes[2];
	int arity, error, niov, nwrite;
	bool is_delayed;

	(void)argc;
	if ((tap = erx_tap_handle(env, argv[0])) == NULL)
		return (enif_make_badarg(env));
	if (enif_get_tuple(env, argv[1], &arity, &parts) &&
	    arity == ERX_TAP_RUN_ARITY && enif_is_identical(parts[0], atom_run))
		return (erx_tap_send_run(env, tap, parts));
	if (!erx_tap_frame_term(env, argv[1], &frame, &is_delayed, &start,
	    &field))
		return (enif_make_badarg(env));
	switch (erx_tap_walk(env, frame, iov, &niov, &len)) {
	case ERX_TAP_WALK_IOV:
		break;
	case ERX_TAP_WALK_JOIN:
		if (!enif_inspect_iolist_as_binary(env, frame, &joined))
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
	write_iov = iov;
	nwrite = niov;
	if (is_delayed) {
		if (!erx_tap_finish(iov, niov, len, start, field, field_bytes,
		    finished, &nwrite))
			return (enif_make_badarg(env));
		write_iov = finished;
	}
	kind = erx_tap_write(tap, write_iov, nwrite, len, &error);
	if (kind != ERX_TAP_WRITE_TAKEN)
		return (erx_tap_not_taken(env, tap, kind, error));
	return (erx_tap_ok(env, 1));
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
	atom_csum = enif_make_atom(env, "csum");
	atom_drop = enif_make_atom(env, "drop");
	atom_eof = enif_make_atom(env, "eof");
	atom_error = enif_make_atom(env, "error");
	atom_erx_tap = enif_make_atom(env, "erx_tap");
	atom_full = enif_make_atom(env, "full");
	atom_malformed = enif_make_atom(env, "malformed");
	atom_more = enif_make_atom(env, "more");
	atom_none = enif_make_atom(env, "none");
	atom_ok = enif_make_atom(env, "ok");
	atom_partial = enif_make_atom(env, "partial");
	atom_readable = enif_make_atom(env, "readable");
	atom_refused = enif_make_atom(env, "refused");
	atom_run = enif_make_atom(env, "run");
	atom_sum = enif_make_atom(env, "sum");
	atom_too_long = enif_make_atom(env, "too_long");
	atom_undefined = enif_make_atom(env, "undefined");
	atom_writable = enif_make_atom(env, "writable");
	return (0);
}

static ErlNifFunc nif_funcs[] = {
	{ "adopt", 2, erx_tap_adopt, 0 },
	{ "open", 2, erx_tap_open, 0 },
	{ "recv", 1, erx_tap_recv, 0 },
	{ "send", 2, erx_tap_send, 0 },
};

ERL_NIF_INIT(erx_tap_nif, nif_funcs, erx_tap_load, NULL, NULL, NULL)
