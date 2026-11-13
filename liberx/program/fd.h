/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_FD_H
#define LIBERX_PROGRAM_FD_H

/*
 * A program's descriptor table (docs/design-programs.md, "Descriptors and
 * files"): ERX_PROG_FDS_MAX slots, each empty or holding a reference to an
 * object of one of a closed set of kinds.  The table has one lock, which
 * guards its slots, every object's count of references and the list of the
 * objects reports can name, and is never held across a wait.  A call takes
 * a counted reference under the lock and works on the object after letting
 * the lock go, so a close empties its slot at once and the object goes with
 * its last reference, whichever thread drops it.
 *
 * The event executor never takes a counted reference: it finds the pipe end
 * a report names under the table lock and locks the end before it lets the
 * table lock go (erx_prog_fd_find_end), so an end it holds cannot be let go
 * under it.  The lock order is the table's, then an end's.
 *
 * Every operation is a switch on the object's kind with no default arm, so
 * a new kind makes the compiler name each operation that must handle it.
 */

#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <erx/prog_profile.h>

struct erx_pipe_end;

typedef enum erx_prog_obj_kind {
	ERX_PROG_OBJ_NULL,	/* null: the one object of its kind, never let go */
	ERX_PROG_OBJ_PIPE,	/* a pipe end, the head of an erx_pipe_end_t */
	ERX_PROG_OBJ_MEM	/* a mem range the session mapped into the program (fd.c) */
} erx_prog_obj_kind_t;

/*
 * The head of every object.  refs counts the slots and the calls in
 * progress that hold it; prev and next link it into the table's list of
 * objects that reports name.  All three are the table lock's.
 */
typedef struct erx_prog_obj {
	erx_prog_obj_kind_t	 kind;
	uint32_t		 refs;
	struct erx_prog_obj	*prev;
	struct erx_prog_obj	*next;
} erx_prog_obj_t;

/*
 * Builds the table from the startup message's descriptors, which the plan
 * accepted (startup.h): a null object for null, an end object set up from
 * its descriptor for a pipe's read or write end, and a mem object for a mem
 * range, which names memory the session already mapped and maps nothing.  The event executor
 * calls it before main, alone.  ERX_OK, or the status of the first
 * descriptor that could not be set up, after which the program stops.
 */
int	erx_prog_fd_setup(erx_prog_fds_iter_t fds);

/* A counted reference to the object in slot fd, or NULL for an empty or out-of-range slot. */
erx_prog_obj_t	*erx_prog_fd_get(int fd);
/* Drops a reference erx_prog_fd_get took; the last one lets the object go. */
void	erx_prog_obj_put(erx_prog_obj_t *obj);
/* Puts a reference to fd's object in the lowest empty slot: that slot, -EBADF or -EMFILE. */
int	erx_prog_fd_dup(int fd);
/* Empties slot fd and drops its reference: 0 or -EBADF. */
int	erx_prog_fd_close(int fd);
/*
 * read and write on slot fd, holding a counted reference for the call: a
 * count or a negative errno, -EBADF for an empty slot and -EINVAL for a
 * len above SSIZE_MAX, as FreeBSD refuses it.  null reads as the end of
 * the stream and takes every byte written, as /dev/null does.  A mem range
 * is no stream: both fail with -ESPIPE.
 */
ssize_t	erx_prog_fd_read(int fd, void *buf, size_t len);
ssize_t	erx_prog_fd_write(int fd, const void *buf, size_t len);

/*
 * mmap of slot fd (docs/design-programs.md#the-startup-message).  Only a
 * mem range maps, and it is mapped already: with flags MAP_SHARED alone,
 * offset 0, a len of 1 to the range's bytes and prot within PROT_READ |
 * PROT_WRITE, *addr is the address the session mapped it at.  0, or
 * -EBADF for an empty slot, -ENODEV for an object of another kind, -EINVAL
 * for any other flags, offset or len, and -EACCES for any other prot.
 */
int	erx_prog_fd_mmap(int fd, size_t len, int prot, int flags, off_t offset, void **addr);
/*
 * fstat of slot fd: 0, or -EBADF for an empty slot.  null is a character
 * device of mode 0666, a pipe end a FIFO of mode 0600 and size 0, and a mem
 * range a regular file of mode 0600 whose size is its bytes (their parity
 * with FreeBSD is unverified, TODO.md).  Every other field is 0.
 */
int	erx_prog_fd_fstat(int fd, struct stat *st);

/*
 * The executor's: the end a report or a doorbell's label names by pipe and
 * end number, locked with erx_pipe_end_lock, or NULL when the program holds
 * no such end.  The caller unlocks it with erx_pipe_end_unlock.
 */
struct erx_pipe_end	*erx_prog_fd_find_end(uint32_t pipe, uint32_t end);
/* The executor's: calls fn on each end the program holds, each under its lock. */
void	erx_prog_fd_each_end(void (*fn)(struct erx_pipe_end *));

#endif /* !LIBERX_PROGRAM_FD_H */
