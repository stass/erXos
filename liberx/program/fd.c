/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A program's descriptor table (fd.h).  The slots, every object's refs and
 * the list of live objects are table_lock's.  A pipe end, the one kind a
 * report names, is linked into the list with its first reference and
 * unlinked with its last, under the lock, so the executor finds only ends
 * some slot or call still holds; null and a mem range never join it.  The
 * object's own release runs after the lock is let go: a pipe end's waits
 * out an executor that found it before the unlink by taking the end's lock
 * (pipe.c), and sends its notices without the table lock held.
 *
 * The lock order is the table's, then an end's: every taking of the table
 * lock goes through table_take, which stops a thread that holds an end's
 * lock, so a wrong order fails at once in every build instead of
 * deadlocking under one schedule.
 */

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "erx/abi.h"
#include "liberx/program/fd.h"
#include "liberx/program/pages.h"
#include "liberx/program/pipe.h"

static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;
static erx_prog_obj_t *slots[ERX_PROG_FDS_MAX];
static erx_prog_obj_t *live;
static erx_prog_obj_t null_obj = { .kind = ERX_PROG_OBJ_NULL };

/*
 * A mem range of the startup message: bytes of memory at address that the
 * session mapped read-write into the program while it built it.  The
 * program holds no capability to it, so the object owns nothing but itself:
 * closing its last descriptor leaves the mapping, as closing a file's does.
 * No report names it, so it never joins the live list.
 */
typedef struct erx_prog_mem {
	erx_prog_obj_t	 obj;		/* first, so a head is its object */
	uintptr_t	 address;
	size_t		 bytes;
} erx_prog_mem_t;

static erx_prog_mem_t *
mem_of(erx_prog_obj_t *obj)
{
	return ((erx_prog_mem_t *)obj);
}

/* Takes table_lock; a thread that holds an end's lock has broken the lock order and stops. */
static void
table_take(void)
{
	if (erx_pipe_end_held())
		__builtin_trap();
	(void)pthread_mutex_lock(&table_lock);
}

/* Takes a reference; the first links the object into the live list.  The caller holds table_lock. */
static void
obj_hold(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		return;
	case ERX_PROG_OBJ_PIPE:
		if (obj->refs++ == 0) {
			obj->prev = NULL;
			obj->next = live;
			if (live != NULL)
				live->prev = obj;
			live = obj;
		}
		return;
	case ERX_PROG_OBJ_MEM:
		obj->refs++;
		return;
	}
}

/*
 * Drops a reference; true when it was the last, and the object then is out
 * of the live list and the caller's to let go.  The caller holds table_lock.
 */
static bool
obj_drop(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		return (false);
	case ERX_PROG_OBJ_PIPE:
		if (--obj->refs != 0)
			return (false);
		if (obj->prev != NULL)
			obj->prev->next = obj->next;
		else
			live = obj->next;
		if (obj->next != NULL)
			obj->next->prev = obj->prev;
		obj->prev = obj->next = NULL;
		return (true);
	case ERX_PROG_OBJ_MEM:
		return (--obj->refs == 0);
	}
	return (false);
}

/* Lets go of an object whose last reference went; no lock held. */
static void
obj_release(erx_prog_obj_t *obj)
{
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		return;
	case ERX_PROG_OBJ_PIPE:
		erx_pipe_release(erx_pipe_end_of(obj));
		return;
	case ERX_PROG_OBJ_MEM:
		erx_prog_pages_give(obj, sizeof(erx_prog_mem_t));
		return;
	}
}

static bool
fd_valid(int fd)
{
	return (fd >= 0 && (uint32_t)fd < ERX_PROG_FDS_MAX);
}

/* Puts obj, with a new reference, into the empty slot fd; false when fd is taken or out of range. */
static bool
fd_install(int fd, erx_prog_obj_t *obj)
{
	bool ok;

	table_take();
	ok = fd_valid(fd) && slots[fd] == NULL;
	if (ok) {
		obj_hold(obj);
		slots[fd] = obj;
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (ok);
}

/*
 * A mem object for the range of pages the descriptor names.  The check holds
 * the first page and the count to u32 from 1, so the range lies within
 * 2^45 bytes; the arithmetic is checked all the same, and the size must fit
 * fstat's off_t.
 */
static int
mem_open(const erx_prog_descriptor_t *descriptor, erx_prog_mem_t **out)
{
	const uint64_t page = descriptor->u.mem.mem_page;
	const uint64_t pages = descriptor->u.mem.mem_pages;
	uint64_t address, bytes, end;
	erx_prog_mem_t *mem;

	if (__builtin_mul_overflow(page, (uint64_t)ERX_PAGE_SIZE, &address) ||
	    __builtin_mul_overflow(pages, (uint64_t)ERX_PAGE_SIZE, &bytes) ||
	    __builtin_add_overflow(address, bytes, &end))
		return (ERX_EINVAL);
	if (end > UINTPTR_MAX || bytes > (uint64_t)INT64_MAX)
		return (ERX_EINVAL);
	if ((mem = erx_prog_pages_take(sizeof(*mem))) == NULL)
		return (ERX_ENOMEM);
	*mem = (erx_prog_mem_t){
		.obj = { .kind = ERX_PROG_OBJ_MEM },
		.address = (uintptr_t)address,
		.bytes = (size_t)bytes,
	};
	*out = mem;
	return (ERX_OK);
}

/* One descriptor of the startup message into slot fd. */
static int
fd_setup_one(const erx_prog_fd_entry_t *entry)
{
	erx_pipe_end_t *end;
	erx_prog_mem_t *mem;
	int status;

	switch (entry->descriptor.which) {
	case ERX_PROG_DESCRIPTOR_MEM:
		if ((status = mem_open(&entry->descriptor, &mem)) != ERX_OK)
			return (status);
		if (fd_install(entry->fd, &mem->obj))
			return (ERX_OK);
		erx_prog_pages_give(mem, sizeof(*mem));
		return (ERX_EINVAL);
	case ERX_PROG_DESCRIPTOR_NULL:
		return (fd_install(entry->fd, &null_obj) ? ERX_OK : ERX_EINVAL);
	case ERX_PROG_DESCRIPTOR_PIPE_WRITE:
	case ERX_PROG_DESCRIPTOR_PIPE_READ:
		status = erx_pipe_open(&entry->descriptor, &end);
		if (status != ERX_OK)
			return (status);
		/*
		 * The check's fds are strictly ascending and below the table's size, so the
		 * slot is empty.  Were it not, the program stops and the end goes with its
		 * space: a release here would send {closed} from the executor, which may not
		 * wait for room.
		 */
		return (fd_install(entry->fd, &end->obj) ? ERX_OK : ERX_EINVAL);
	}
	/* The plan refused every other descriptor (startup.c). */
	return (ERX_EINVAL);
}

int
erx_prog_fd_setup(erx_prog_fds_iter_t fds)
{
	erx_prog_fd_entry_t entry;
	int status;

	while (erx_prog_fds_next(&fds, &entry))
		if ((status = fd_setup_one(&entry)) != ERX_OK)
			return (status);
	return (ERX_OK);
}

erx_prog_obj_t *
erx_prog_fd_get(int fd)
{
	erx_prog_obj_t *obj = NULL;

	table_take();
	if (fd_valid(fd) && (obj = slots[fd]) != NULL)
		obj_hold(obj);
	(void)pthread_mutex_unlock(&table_lock);
	return (obj);
}

void
erx_prog_obj_put(erx_prog_obj_t *obj)
{
	bool last;

	table_take();
	last = obj_drop(obj);
	(void)pthread_mutex_unlock(&table_lock);
	if (last)
		obj_release(obj);
}

int
erx_prog_fd_dup(int fd)
{
	int result = -EBADF;

	table_take();
	if (fd_valid(fd) && slots[fd] != NULL) {
		result = -EMFILE;
		for (uint32_t at = 0; at < ERX_PROG_FDS_MAX; at++) {
			if (slots[at] == NULL) {
				obj_hold(slots[fd]);
				slots[at] = slots[fd];
				result = (int)at;
				break;
			}
		}
	}
	(void)pthread_mutex_unlock(&table_lock);
	return (result);
}

int
erx_prog_fd_close(int fd)
{
	erx_prog_obj_t *obj = NULL;
	bool last = false;

	table_take();
	if (fd_valid(fd) && (obj = slots[fd]) != NULL) {
		slots[fd] = NULL;
		last = obj_drop(obj);
	}
	(void)pthread_mutex_unlock(&table_lock);
	if (obj == NULL)
		return (-EBADF);
	if (last)
		obj_release(obj);
	return (0);
}

ssize_t
erx_prog_fd_read(int fd, void *buf, size_t len)
{
	erx_prog_obj_t *obj;
	ssize_t result = 0;

	if (len > SSIZE_MAX)
		return (-EINVAL);
	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		break;
	case ERX_PROG_OBJ_PIPE:
		result = erx_pipe_read(erx_pipe_end_of(obj), buf, len);
		break;
	case ERX_PROG_OBJ_MEM:
		result = -ESPIPE;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

ssize_t
erx_prog_fd_write(int fd, const void *buf, size_t len)
{
	erx_prog_obj_t *obj;
	ssize_t result = (ssize_t)len;

	if (len > SSIZE_MAX)
		return (-EINVAL);
	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		break;
	case ERX_PROG_OBJ_PIPE:
		result = erx_pipe_write(erx_pipe_end_of(obj), buf, len);
		break;
	case ERX_PROG_OBJ_MEM:
		result = -ESPIPE;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

/* Whether a mmap of mem may return its mapping: the one way design-programs.md gives. */
static int
mem_map_check(const erx_prog_mem_t *mem, size_t len, int prot, int flags, off_t offset)
{
	if (flags != MAP_SHARED || offset != 0 || len == 0 || len > mem->bytes)
		return (-EINVAL);
	if ((prot & ~(PROT_READ | PROT_WRITE)) != 0)
		return (-EACCES);
	return (0);
}

int
erx_prog_fd_mmap(int fd, size_t len, int prot, int flags, off_t offset, void **addr)
{
	erx_prog_obj_t *obj;
	int result = -ENODEV;

	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_PIPE:
		break;
	case ERX_PROG_OBJ_MEM:
		result = mem_map_check(mem_of(obj), len, prot, flags, offset);
		if (result == 0)
			*addr = (void *)mem_of(obj)->address;
		break;
	}
	erx_prog_obj_put(obj);
	return (result);
}

int
erx_prog_fd_fstat(int fd, struct stat *st)
{
	erx_prog_obj_t *obj;

	if ((obj = erx_prog_fd_get(fd)) == NULL)
		return (-EBADF);
	memset(st, 0, sizeof(*st));
	switch (obj->kind) {
	case ERX_PROG_OBJ_NULL:
		st->st_mode = S_IFCHR | 0666;
		break;
	case ERX_PROG_OBJ_PIPE:
		st->st_mode = S_IFIFO | 0600;
		break;
	case ERX_PROG_OBJ_MEM:
		st->st_mode = S_IFREG | 0600;
		st->st_size = (off_t)mem_of(obj)->bytes;
		break;
	}
	erx_prog_obj_put(obj);
	return (0);
}

erx_pipe_end_t *
erx_prog_fd_find_end(uint32_t pipe, uint32_t end)
{
	erx_pipe_end_t *found = NULL;

	table_take();
	for (erx_prog_obj_t *obj = live; obj != NULL && found == NULL; obj = obj->next) {
		switch (obj->kind) {
		case ERX_PROG_OBJ_NULL:
			break;
		case ERX_PROG_OBJ_PIPE:
			if (erx_pipe_end_of(obj)->pipe == pipe && erx_pipe_end_of(obj)->end == end)
				found = erx_pipe_end_of(obj);
			break;
		case ERX_PROG_OBJ_MEM:
			break;
		}
	}
	/* Locked before the table lets go: the end's last release waits for this lock. */
	if (found != NULL)
		erx_pipe_end_lock(found);
	(void)pthread_mutex_unlock(&table_lock);
	return (found);
}

void
erx_prog_fd_each_end(void (*fn)(erx_pipe_end_t *))
{
	table_take();
	for (erx_prog_obj_t *obj = live; obj != NULL; obj = obj->next) {
		switch (obj->kind) {
		case ERX_PROG_OBJ_NULL:
			break;
		case ERX_PROG_OBJ_PIPE:
			erx_pipe_end_lock(erx_pipe_end_of(obj));
			fn(erx_pipe_end_of(obj));
			erx_pipe_end_unlock(erx_pipe_end_of(obj));
			break;
		case ERX_PROG_OBJ_MEM:
			break;
		}
	}
	(void)pthread_mutex_unlock(&table_lock);
}
