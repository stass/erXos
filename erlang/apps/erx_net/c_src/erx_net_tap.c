/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_net_tap: the tap helper of erx_net's pipe, an Erlang port program
 * opened with {packet, 2}.  It relays whole Ethernet frames between the tap
 * device named by its one argument and its standard input and output, and
 * inspects no byte of a frame:
 *
 *  - each read of the tap is one frame, written to standard output behind
 *    its 2-byte big-endian length;
 *  - on standard input it reads a 2-byte big-endian length and exactly that
 *    many bytes, and writes them to the tap in one write.
 *
 * A tap may discard a frame it is handed, as a wire loses one: a write that
 * takes none of a frame (FreeBSD's tap does this while its interface is
 * down) or fails with ENOBUFS drops that frame, and the relay goes on.
 *
 * The port closing, seen as end of file on standard input between frames or
 * as EPIPE on standard output, ends the helper with status 0.  Anything else
 * that stops the relay (end of file on the tap or inside a frame, a frame
 * the length cannot carry, a write to the tap that takes part of a frame,
 * any other error but EINTR) ends it with status 1 and one line on standard
 * error, once the port has closed (see erx_tap_exit_failed).  Either way
 * the pipe reports its link down.
 */

#define _POSIX_C_SOURCE	200809L

#include <sys/stat.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The length prefix is 2 bytes, so no frame is longer than this. */
#define ERX_TAP_LEN_BYTES	2
#define ERX_TAP_FRAME_MAX	65535

static _Noreturn void erx_tap_exit_failed(void);
static _Noreturn void erx_tap_fail(const char *what, int error);
static bool	erx_tap_from_port(int tap);
static size_t	erx_tap_read_port(uint8_t *buf, size_t len);
static bool	erx_tap_to_port(int tap);
static bool	erx_tap_write_port(const uint8_t *buf, size_t len);

static const char	*erx_tap_device;

/*
 * Frames bound for the port: the length prefix and the frame, one more byte
 * than the longest frame so that a longer one shows as a full read.
 */
static uint8_t	erx_tap_out[ERX_TAP_LEN_BYTES + ERX_TAP_FRAME_MAX + 1];

/* Frames bound for the tap. */
static uint8_t	erx_tap_in[ERX_TAP_FRAME_MAX];

/*
 * The one way the helper fails: one line on standard error, then status 1.
 * error is an errno value, or 0 for none.
 */
static _Noreturn void
erx_tap_fail(const char *what, int error)
{
	if (error != 0)
		fprintf(stderr, "erx_net_tap: %s: %s: %s\n", erx_tap_device,
		    what, strerror(error));
	else
		fprintf(stderr, "erx_net_tap: %s: %s\n", erx_tap_device, what);
	erx_tap_exit_failed();
}

/*
 * Exits with status 1 only once the port has closed.  Closing standard
 * output makes the port close; until then standard input stays open and is
 * read and discarded, so a frame the port is still writing never meets a
 * closed pipe.  ERTS fails a port whose write meets a closed pipe with
 * reason epipe, and that exit signal would end the driver linked to it.
 */
static _Noreturn void
erx_tap_exit_failed(void)
{
	ssize_t n;

	fflush(stderr);
	close(STDOUT_FILENO);
	/*
	 * The bytes are discarded unseen.  A read error other than EINTR, which
	 * a pipe does not give, ends the wait as end of file would.
	 */
	do {
		n = read(STDIN_FILENO, erx_tap_in, sizeof(erx_tap_in));
	} while (n > 0 || (n < 0 && errno == EINTR));
	exit(1);
}

/*
 * Reads len bytes from standard input, however many reads that takes, and
 * returns how many it got: len, or fewer when end of file came first.
 */
static size_t
erx_tap_read_port(uint8_t *buf, size_t len)
{
	size_t got;
	ssize_t n;

	got = 0;
	while (got < len) {
		n = read(STDIN_FILENO, buf + got, len - got);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0)
			erx_tap_fail("read of standard input", errno);
		if (n == 0)
			break;
		got += (size_t)n;
	}
	return (got);
}

/*
 * Writes all len bytes to standard output, continuing a write a signal cuts
 * short, so a frame is never split.  Returns false when the port has closed.
 */
static bool
erx_tap_write_port(const uint8_t *buf, size_t len)
{
	size_t done;
	ssize_t n;

	done = 0;
	while (done < len) {
		n = write(STDOUT_FILENO, buf + done, len - done);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0 && errno == EPIPE)
			return (false);
		if (n < 0)
			erx_tap_fail("write of standard output", errno);
		done += (size_t)n;
	}
	return (true);
}

/*
 * Relays one frame from standard input to the tap.  Returns false when the
 * port has closed between frames.
 */
static bool
erx_tap_from_port(int tap)
{
	uint8_t prefix[ERX_TAP_LEN_BYTES];
	size_t got, len;
	ssize_t n;

	got = erx_tap_read_port(prefix, sizeof(prefix));
	if (got == 0)
		return (false);
	if (got < sizeof(prefix))
		erx_tap_fail("end of file inside a frame's length", 0);
	len = ((size_t)prefix[0] << 8) | prefix[1];
	if (erx_tap_read_port(erx_tap_in, len) < len)
		erx_tap_fail("end of file inside a frame", 0);

	do {
		n = write(tap, erx_tap_in, len);
	} while (n < 0 && errno == EINTR);

	/*
	 * The tap discarded the frame; see the top of the file.  An empty frame
	 * written whole is 0 bytes too, and is no drop.
	 */
	if ((n == 0 && len > 0) || (n < 0 && errno == ENOBUFS))
		return (true);
	if (n < 0)
		erx_tap_fail("write of the tap", errno);

	/* A tap takes a frame in one write; a part of one is no frame. */
	if ((size_t)n != len)
		erx_tap_fail("short write of the tap", 0);
	return (true);
}

/*
 * Relays one frame from the tap to standard output.  Returns false when the
 * port has closed.
 */
static bool
erx_tap_to_port(int tap)
{
	size_t len;
	ssize_t n;

	n = read(tap, erx_tap_out + ERX_TAP_LEN_BYTES, ERX_TAP_FRAME_MAX + 1);

	/* Nothing was read; the next poll finds the frame again. */
	if (n < 0 && errno == EINTR)
		return (true);
	if (n < 0)
		erx_tap_fail("read of the tap", errno);
	if (n == 0)
		erx_tap_fail("end of file on the tap", 0);
	if (n > ERX_TAP_FRAME_MAX)
		erx_tap_fail("frame longer than 65535 bytes", 0);

	len = (size_t)n;
	erx_tap_out[0] = (uint8_t)(len >> 8);
	erx_tap_out[1] = (uint8_t)(len & 0xff);
	return (erx_tap_write_port(erx_tap_out, ERX_TAP_LEN_BYTES + len));
}

int
main(int argc, char *argv[])
{
	struct pollfd fds[2];
	struct stat st;
	bool open_port;
	int tap;

	if (argc != 2) {
		fprintf(stderr, "usage: erx_net_tap DEVICE\n");
		erx_tap_exit_failed();
	}
	erx_tap_device = argv[1];

	/* A closed standard output is the port closing, not a signal. */
	if (signal(SIGPIPE, SIG_IGN) == SIG_ERR)
		erx_tap_fail("ignoring SIGPIPE", errno);
	tap = open(erx_tap_device, O_RDWR | O_CLOEXEC);
	if (tap < 0)
		erx_tap_fail("open", errno);

	/* A regular file named by mistake would take frames and be overwritten. */
	if (fstat(tap, &st) < 0)
		erx_tap_fail("fstat", errno);
	if (S_ISREG(st.st_mode))
		erx_tap_fail("a regular file, not a device", 0);

	fds[0] = (struct pollfd){ .fd = STDIN_FILENO, .events = POLLIN };
	fds[1] = (struct pollfd){ .fd = tap, .events = POLLIN };
	open_port = true;
	while (open_port) {
		if (poll(fds, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			erx_tap_fail("poll", errno);
		}
		if ((fds[0].revents | fds[1].revents) & POLLNVAL)
			erx_tap_fail("poll: descriptor not open", 0);

		/*
		 * Hang-up and error are served by the read, which then
		 * reports end of file or the error itself.
		 */
		if (fds[0].revents & (POLLIN | POLLHUP | POLLERR))
			open_port = erx_tap_from_port(tap);
		if (open_port && (fds[1].revents & (POLLIN | POLLHUP | POLLERR)))
			open_port = erx_tap_to_port(tap);
	}
	return (0);
}
