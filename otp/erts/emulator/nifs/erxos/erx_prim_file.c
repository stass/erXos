/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * prim_file's platform layer over the namespace (design-runtime.md, Files;
 * design-files.md, Erlang clients). Every path passes erx_ns_resolve once, when it
 * is marshalled. The one provider served here is the release file system,
 * read-only; a path on a file server's grant answers {remote, Pid, Names}, and
 * prim_file runs the operation in the calling process through erx_file_remote. A
 * handle holds a file of the release and a position, under prim_file_nif.c's
 * per-file state, and no file descriptor exists anywhere in the layer.
 *
 * The namespace, its table and its working directory, is one per runtime, and
 * erx_ns's mount, bind and unmount change it at run time for every process at
 * once. One reader-writer lock, ns_lock, guards it, rather than swapping copies:
 * the table is about 530 KiB, too large to copy for each change, and a copy
 * swapped out could be freed only once its last reader is known to be done, a
 * second mechanism with nothing to gain while changes are rare. Under the read
 * lock, marshalling resolves a path and copies out all the operation needs (the
 * result, the mount's kind and the grant's pid), so nothing a reader keeps points
 * into the table, and a change made after the lock is released cannot reach it.
 *
 * Every grant pid in the table is watched by one monitor, all held by the one
 * resource ns_watcher. When the process ends, its entries keep their place and
 * answer eio until they are unmounted, so a pid the runtime later gives another
 * process never receives a mounted path's requests. The monitors follow from the
 * table: after each change, erx_ns_watch_table monitors each pid the table holds
 * and drops each monitor of a pid it no longer holds.
 *
 * The runtime's fid counter lives beside the namespace (design-files.md, Version
 * and attach): one 64-bit atomic, which a draw adds one to and keeps the low 32
 * bits of, drawing again for NOFID, so no process allocates fids.
 *
 * The table of release names is built once, when the NIF loads, and is immutable
 * afterwards, so its readers take no lock. The flags of file_checked guard no data.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "erl_nif.h"
#include "sys.h"

#include "prim_file_nif.h"

#include <errno.h>
#include <string.h>
#include <sys/stat.h>

#include "erx/ns.h"
#include "erx/release.h"
#include "erx/release_fs.h"

/* As stock reports them: st_mode, with the type's bits. */
#define ERX_FILE_MODE		(S_IFREG | 0444)
#define ERX_DIRECTORY_MODE	(S_IFDIR | 0555)

typedef struct erx_efile {
	efile_data_t	common;
	uint32_t	file;
	Sint64		position;
} erx_efile_t;

/* A local pid is an immediate term, so its word names it for as long as it lives. */
_Static_assert(sizeof(ERL_NIF_TERM) <= sizeof(uint64_t), "a pid fits an entry's server");

typedef struct erx_ns_watch {
	uint64_t	server;
	ErlNifMonitor	monitor;
} erx_ns_watch_t;

static erx_ns_t		name_space;
static ErlNifRWLock	*ns_lock;
/* Under ns_lock: at most one per entry, since each watches a pid an entry holds. */
static erx_ns_watch_t	ns_watches[ERX_NS_MOUNTS_MAX];
static uint32_t		ns_nwatches;
static ErlNifResourceType *ns_watcher_type;
static void		*ns_watcher;
static erts_atomic64_t	fid_counter;
static erx_release_fs_t	release_fs;
/*
 * Per file, whether it has passed erx_release_check. Only ever goes from 0 to 1 and
 * guards no data, so two opens racing hash twice and nothing worse.
 */
static erts_atomic32_t	*file_checked;

static int erx_build_table(void);
static posix_errno_t erx_ns_errno(erx_ns_status_t);
static ERL_NIF_TERM erx_ns_answer(ErlNifEnv *, erx_ns_status_t);
static int erx_inspect_path(ErlNifEnv *, ERL_NIF_TERM, ErlNifBinary *);
static ErlNifPid erx_pid_of(uint64_t);
static bool erx_ns_holds(uint64_t);
static void erx_ns_end_server(uint64_t);
static void erx_ns_watch_table(ErlNifEnv *);
static void erx_ns_down(ErlNifEnv *, void *, ErlNifPid *, ErlNifMonitor *);
static posix_errno_t erx_find(const efile_path_t *, erx_release_fs_kind_t *,
    uint32_t *);
static posix_errno_t erx_find_existing(const efile_path_t *,
    erx_release_fs_kind_t *, uint32_t *);
static Sint64 erx_copy_out(uint32_t, Sint64, SysIOVec *, int);
static posix_errno_t erx_check_file(uint32_t);
static void erx_fill_info(erx_release_fs_kind_t, uint64_t, efile_fileinfo_t *);

/*
 * The table of names, from the one reader of the index. A table that cannot be
 * allocated fails the NIF's load, which ends the start.
 */
static int
erx_build_table(void)
{
	/* An entry holds a whole path, large for a stack, and the one call owns it. */
	static erx_release_entry_t entry;
	erx_release_fs_file_t *files;
	erts_atomic32_t *checked;
	uint8_t *strings;
	uint64_t count, bytes, used;

	count = 0;
	bytes = 0;
	while (erx_release_entry(count, &entry) == 0) {
		bytes += entry.path_length;
		count++;
	}
	files = enif_alloc((size_t)count * sizeof(*files));
	strings = enif_alloc((size_t)bytes);
	checked = enif_alloc((size_t)count * sizeof(*checked));
	if (files == NULL || strings == NULL || checked == NULL) {
		enif_fprintf(stderr, "prim_file: no memory for the release's %lu names\n",
		    (unsigned long)count);
		return (-1);
	}
	used = 0;
	for (uint64_t index = 0; index < count; index++) {
		if (erx_release_entry(index, &entry) != 0)
			return (-1);
		memcpy(strings + used, entry.path, entry.path_length);
		files[index] = (erx_release_fs_file_t){ .path = strings + used,
		    .length = entry.path_length, .size = entry.size,
		    .offset = entry.offset };
		erts_atomic32_init_nob(&checked[index], 0);
		used += entry.path_length;
	}
	file_checked = checked;
	release_fs = (erx_release_fs_t){ .files = files, .count = (uint32_t)count };
	return (0);
}

int
efile_load(ErlNifEnv *env)
{
	/* members counts dtor, stop and down: without it the down callback is not seen. */
	ErlNifResourceTypeInit callbacks = { .down = erx_ns_down, .members = 3 };

	name_space.count = 1;
	name_space.mounts[0].kind = ERX_NS_RELEASE;
	name_space.mounts[0].rights = ERX_NS_RO;
	name_space.mounts[0].point[0] = '/';
	name_space.mounts[0].root[0] = '/';
	name_space.cwd[0] = '/';
	erts_atomic64_init_nob(&fid_counter, 0);
	ns_lock = enif_rwlock_create("erx_prim_file_ns");
	if (ns_lock == NULL)
		return (-1);
	ns_watcher_type = enif_init_resource_type(env, "erx_ns_watcher", &callbacks,
	    ERL_NIF_RT_CREATE, NULL);
	if (ns_watcher_type == NULL)
		return (-1);
	return (erx_build_table());
}

/* What erx_ns_resolve refuses a path with. */
static posix_errno_t
erx_ns_errno(erx_ns_status_t status)
{
	switch (status) {
	case ERX_NS_OK:
		return (0);
	case ERX_NS_ENAMETOOLONG:
		return (ENAMETOOLONG);
	case ERX_NS_ENOENT:
		return (ENOENT);
	case ERX_NS_EEXIST:
		return (EEXIST);
	case ERX_NS_EBUSY:
		return (EBUSY);
	case ERX_NS_EINVAL:
	case ERX_NS_ELIMIT:
		break;
	}
	return (EINVAL);
}

/* A change's answer to erx_ns: ok, or {error, Reason}; a full table is system_limit. */
static ERL_NIF_TERM
erx_ns_answer(ErlNifEnv *env, erx_ns_status_t status)
{
	const char *reason = "einval";

	switch (status) {
	case ERX_NS_OK:
		return (enif_make_atom(env, "ok"));
	case ERX_NS_ENAMETOOLONG:
		reason = "enametoolong";
		break;
	case ERX_NS_ENOENT:
		reason = "enoent";
		break;
	case ERX_NS_EEXIST:
		reason = "eexist";
		break;
	case ERX_NS_EBUSY:
		reason = "ebusy";
		break;
	case ERX_NS_ELIMIT:
		reason = "system_limit";
		break;
	case ERX_NS_EINVAL:
		reason = "einval";
		break;
	}
	return (enif_make_tuple2(env, enif_make_atom(env, "error"),
	    enif_make_atom(env, reason)));
}

/* A path as prim_file encodes it: a binary ending in its one NUL. */
static int
erx_inspect_path(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *path)
{
	return (enif_inspect_binary(env, term, path) && path->size > 0 &&
	    path->data[path->size - 1] == '\0');
}

static ErlNifPid
erx_pid_of(uint64_t server)
{
	ErlNifPid pid;

	pid.pid = (ERL_NIF_TERM)server;
	return (pid);
}

/*
 * Marshalling resolves the path, and copies out under the lock all the
 * operation needs. A path on a grant answers {remote, Pid, Names}, or eio once
 * the grant's process has ended.
 */
posix_errno_t
efile_marshal_path(ErlNifEnv *env, ERL_NIF_TERM path, efile_path_t *result)
{
	const erx_ns_mount_t *mount;
	erx_ns_status_t status;
	ERL_NIF_TERM names;
	uint64_t server;

	if (!erx_inspect_path(env, path, &result->bytes))
		return (EINVAL);
	result->on_mount = 0;
	result->kind = ERX_NS_RELEASE;
	server = 0;
	enif_rwlock_rlock(ns_lock);
	status = erx_ns_resolve(&name_space, result->bytes.data, result->bytes.size - 1,
	    &result->result);
	mount = result->result.res_mount;
	if (status == ERX_NS_OK && mount != NULL) {
		result->on_mount = 1;
		result->kind = mount->kind;
		server = mount->server;
	}
	enif_rwlock_runlock(ns_lock);
	if (status != ERX_NS_OK)
		return (erx_ns_errno(status));
	if (!result->on_mount || result->kind != ERX_NS_SERVER)
		return (0);
	if (server == 0)
		return (EIO);
	memcpy(enif_make_new_binary(env, result->result.res_names_length, &names),
	    result->result.res_names, result->result.res_names_length);
	result->remote = enif_make_tuple3(env, enif_make_atom(env, "remote"),
	    (ERL_NIF_TERM)server, names);
	return (EFILE_EREMOTE);
}

posix_errno_t
efile_marshal_text(ErlNifEnv *env, ERL_NIF_TERM text, efile_path_t *result)
{
	if (!erx_inspect_path(env, text, &result->bytes))
		return (EINVAL);
	result->on_mount = 0;
	result->kind = ERX_NS_RELEASE;
	return (0);
}

/* Under ns_lock: whether an entry still names the grant. */
static bool
erx_ns_holds(uint64_t server)
{
	for (uint32_t index = 0; index < name_space.count; index++) {
		if (name_space.mounts[index].kind == ERX_NS_SERVER &&
		    name_space.mounts[index].server == server)
			return (true);
	}
	return (false);
}

/* Under ns_lock, held for writing: the grant's entries answer eio from now on. */
static void
erx_ns_end_server(uint64_t server)
{
	for (uint32_t index = 0; index < name_space.count; index++) {
		if (name_space.mounts[index].kind == ERX_NS_SERVER &&
		    name_space.mounts[index].server == server)
			name_space.mounts[index].server = 0;
	}
}

/*
 * Under ns_lock, held for writing: one monitor for each pid the table holds and
 * none for any other. A pid that has already ended when it is first watched ends
 * its entries at once.
 */
static void
erx_ns_watch_table(ErlNifEnv *env)
{
	ErlNifMonitor monitor;
	ErlNifPid pid;
	uint64_t server;
	uint32_t index;
	int watching;
	bool watched;

	/*
	 * The type takes its down callback only once the load has returned, so the one
	 * watcher is made at the first change. It is held for the runtime's life:
	 * dropping it would drop every monitor.
	 */
	if (ns_watcher == NULL)
		ns_watcher = enif_alloc_resource(ns_watcher_type, 1);
	for (index = 0; index < ns_nwatches;) {
		if (erx_ns_holds(ns_watches[index].server)) {
			index++;
			continue;
		}
		/* A monitor that has already fired is gone, which is all this asks. */
		(void)enif_demonitor_process(env, ns_watcher, &ns_watches[index].monitor);
		ns_watches[index] = ns_watches[--ns_nwatches];
	}
	for (index = 0; index < name_space.count; index++) {
		server = name_space.mounts[index].server;
		if (name_space.mounts[index].kind != ERX_NS_SERVER || server == 0)
			continue;
		watched = false;
		for (uint32_t other = 0; other < ns_nwatches && !watched; other++)
			watched = ns_watches[other].server == server;
		if (watched)
			continue;
		pid = erx_pid_of(server);
		watching = enif_monitor_process(env, ns_watcher, &pid, &monitor);
		if (watching < 0) {
			/* No down callback: a fault of this file, which no input reaches. */
			enif_fprintf(stderr, "prim_file: the namespace cannot watch its grants\n");
			abort();
		}
		if (watching == 0) {
			ns_watches[ns_nwatches++] = (erx_ns_watch_t){ .server = server,
			    .monitor = monitor };
		} else {
			erx_ns_end_server(server);
		}
	}
}

/*
 * A grant's process ended: its entries stay, answering eio, until unmounted. Only
 * a monitor the table still holds counts, so a callback that waited for the lock
 * while the pid was unmounted and given to another process ends nothing.
 */
static void
erx_ns_down(ErlNifEnv *env, void *watcher, ErlNifPid *pid, ErlNifMonitor *monitor)
{
	(void)watcher;
	enif_rwlock_rwlock(ns_lock);
	for (uint32_t index = 0; index < ns_nwatches; index++) {
		if (enif_compare_monitors(&ns_watches[index].monitor, monitor) == 0) {
			erx_ns_end_server((uint64_t)pid->pid);
			erx_ns_watch_table(env);
			break;
		}
	}
	enif_rwlock_rwunlock(ns_lock);
}

/* prim_file:erx_ns_mount_nif(Point, Pid, Tree, Rights), Rights one of ro, rw and rx. */
ERL_NIF_TERM
efile_ns_mount_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	static const char *const rights_names[] = {
		[ERX_NS_RO] = "ro", [ERX_NS_RW] = "rw", [ERX_NS_RX] = "rx"
	};
	ErlNifBinary point, tree;
	erx_ns_rights_t rights;
	erx_ns_status_t status;
	ErlNifPid pid;
	char atom[3];

	if (argc != 4 || !erx_inspect_path(env, argv[0], &point) ||
	    !enif_get_local_pid(env, argv[1], &pid) ||
	    !enif_inspect_binary(env, argv[2], &tree) ||
	    enif_get_atom(env, argv[3], atom, sizeof(atom), ERL_NIF_LATIN1) == 0)
		return (enif_make_badarg(env));
	for (rights = ERX_NS_RO; rights <= ERX_NS_RX; rights++) {
		if (strcmp(atom, rights_names[rights]) == 0)
			break;
	}
	if (rights > ERX_NS_RX)
		return (enif_make_badarg(env));
	enif_rwlock_rwlock(ns_lock);
	status = erx_ns_mount(&name_space, point.data, point.size - 1,
	    (uint64_t)enif_make_pid(env, &pid), tree.data, tree.size, rights);
	if (status == ERX_NS_OK)
		erx_ns_watch_table(env);
	enif_rwlock_rwunlock(ns_lock);
	return (erx_ns_answer(env, status));
}

/* prim_file:erx_ns_bind_nif(From, To, ReadOnly). */
ERL_NIF_TERM
efile_ns_bind_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary from, to;
	erx_ns_status_t status;
	char read_only[6];

	if (argc != 3 || !erx_inspect_path(env, argv[0], &from) ||
	    !erx_inspect_path(env, argv[1], &to) ||
	    enif_get_atom(env, argv[2], read_only, sizeof(read_only), ERL_NIF_LATIN1) == 0 ||
	    (strcmp(read_only, "true") != 0 && strcmp(read_only, "false") != 0))
		return (enif_make_badarg(env));
	enif_rwlock_rwlock(ns_lock);
	status = erx_ns_bind(&name_space, from.data, from.size - 1, to.data,
	    to.size - 1, strcmp(read_only, "true") == 0);
	if (status == ERX_NS_OK)
		erx_ns_watch_table(env);
	enif_rwlock_rwunlock(ns_lock);
	return (erx_ns_answer(env, status));
}

/* prim_file:erx_ns_unmount_nif(Point). */
ERL_NIF_TERM
efile_ns_unmount_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary point;
	erx_ns_status_t status;

	if (argc != 1 || !erx_inspect_path(env, argv[0], &point))
		return (enif_make_badarg(env));
	enif_rwlock_rwlock(ns_lock);
	status = erx_ns_unmount(&name_space, point.data, point.size - 1);
	if (status == ERX_NS_OK)
		erx_ns_watch_table(env);
	enif_rwlock_rwunlock(ns_lock);
	return (erx_ns_answer(env, status));
}

/* prim_file:erx_fid_nif(): one draw of the runtime's fid counter. */
ERL_NIF_TERM
efile_fid_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uint32_t fid;

	(void)argc;
	(void)argv;
	while (!erx_ns_fid_of((uint64_t)erts_atomic64_inc_read_nob(&fid_counter), &fid))
		continue;
	return (enif_make_uint(env, fid));
}

/* New kinds of file are new rows here; the callers below do not move. */
static posix_errno_t
erx_find(const efile_path_t *path, erx_release_fs_kind_t *kind, uint32_t *file)
{
	if (!path->on_mount || path->kind != ERX_NS_RELEASE)
		return (ENOTSUP);
	*kind = erx_release_fs_lookup(&release_fs,
	    (const uint8_t *)path->result.res_names,
	    path->result.res_names_length, file);
	return (0);
}

static posix_errno_t
erx_find_existing(const efile_path_t *path, erx_release_fs_kind_t *kind,
    uint32_t *file)
{
	posix_errno_t error;

	error = erx_find(path, kind, file);
	if (error != 0)
		return (error);
	switch (*kind) {
	case ERX_RELEASE_FS_FILE:
	case ERX_RELEASE_FS_DIRECTORY:
		return (0);
	case ERX_RELEASE_FS_NOT_DIRECTORY:
		return (ENOTDIR);
	case ERX_RELEASE_FS_MISSING:
		return (ENOENT);
	}
	return (ENOENT);
}

ERL_NIF_TERM
efile_get_handle(ErlNifEnv *env, efile_data_t *d)
{
	ERL_NIF_TERM handle;

	(void)d;
	(void)enif_make_new_binary(env, 0, &handle);
	return (handle);
}

posix_errno_t
efile_dup_handle(ErlNifEnv *env, efile_data_t *d, ErlNifEvent *handle)
{
	(void)env;
	(void)d;
	(void)handle;
	return (ENOTSUP);
}

/*
 * The archive's index is checked at bind, its files here: the first open of each
 * hashes it, so a changed byte of the immutable archive never reaches a read. A
 * refused file is hashed again at its next open. The file's path is the archive's
 * text, and stays out of the diagnostic.
 */
static posix_errno_t
erx_check_file(uint32_t file)
{
	const char *reason;

	if (erts_atomic32_read_nob(&file_checked[file]) != 0)
		return (0);
	/* The table's index is in the run, so the call never answers ERX_ERANGE. */
	reason = "file";
	if (erx_release_check(file, &reason) != 0) {
		enif_fprintf(stderr, "prim_file: release file %lu refused by check %s\n",
		    (unsigned long)file, reason);
		return (EIO);
	}
	erts_atomic32_set_nob(&file_checked[file], 1);
	return (0);
}

posix_errno_t
efile_open(const efile_path_t *path, enum efile_modes_t modes,
    ErlNifResourceType *nif_type, efile_data_t **d)
{
	erx_release_fs_kind_t kind;
	erx_efile_t *handle;
	posix_errno_t error;
	uint32_t file;

	*d = NULL;
	if ((modes & (EFILE_MODE_WRITE | EFILE_MODE_APPEND | EFILE_MODE_EXCLUSIVE)) != 0)
		return (EROFS);
	error = erx_find_existing(path, &kind, &file);
	if (error != 0)
		return (error);
	if (kind == ERX_RELEASE_FS_DIRECTORY)
		return ((modes & EFILE_MODE_DIRECTORY) != 0 ? ENOTSUP : EISDIR);
	if ((modes & EFILE_MODE_DIRECTORY) != 0)
		return (ENOTDIR);
	error = erx_check_file(file);
	if (error != 0)
		return (error);
	handle = (erx_efile_t *)enif_alloc_resource(nif_type, sizeof(*handle));
	handle->file = file;
	handle->position = 0;
	EFILE_INIT_RESOURCE(&handle->common, modes);
	*d = &handle->common;
	return (0);
}

posix_errno_t
efile_from_fd(int fd, ErlNifResourceType *nif_type, efile_data_t **d)
{
	(void)fd;
	(void)nif_type;
	*d = NULL;
	return (ENOTSUP);
}

int
efile_close(efile_data_t *d, posix_errno_t *error)
{
	(void)error;
	ASSERT(erts_atomic32_read_nob(&d->state) == EFILE_STATE_CLOSED);
	enif_release_resource(d);
	return (1);
}

/* offset is at least zero; past the end there is nothing to copy. */
static Sint64
erx_copy_out(uint32_t file, Sint64 offset, SysIOVec *iov, int iovlen)
{
	const erx_release_fs_file_t *entry;
	const uint8_t *data;
	uint64_t remaining;
	size_t count;
	Sint64 total;

	entry = &release_fs.files[file];
	if ((uint64_t)offset >= entry->size)
		return (0);
	data = erx_release_addr() + entry->offset + (uint64_t)offset;
	remaining = entry->size - (uint64_t)offset;
	total = 0;
	for (int index = 0; index < iovlen && remaining > 0; index++) {
		count = iov[index].iov_len < remaining ?
		    iov[index].iov_len : (size_t)remaining;
		memcpy(iov[index].iov_base, data, count);
		data += count;
		remaining -= count;
		total += (Sint64)count;
	}
	return (total);
}

Sint64
efile_readv(efile_data_t *d, SysIOVec *iov, int iovlen)
{
	erx_efile_t *handle = (erx_efile_t *)d;
	Sint64 count;

	count = erx_copy_out(handle->file, handle->position, iov, iovlen);
	handle->position += count;
	return (count);
}

Sint64
efile_preadv(efile_data_t *d, Sint64 offset, SysIOVec *iov, int iovlen)
{
	erx_efile_t *handle = (erx_efile_t *)d;

	if (offset < 0) {
		d->posix_errno = EINVAL;
		return (-1);
	}
	return (erx_copy_out(handle->file, offset, iov, iovlen));
}

Sint64
efile_writev(efile_data_t *d, SysIOVec *iov, int iovlen)
{
	(void)iov;
	(void)iovlen;
	d->posix_errno = EROFS;
	return (-1);
}

Sint64
efile_pwritev(efile_data_t *d, Sint64 offset, SysIOVec *iov, int iovlen)
{
	(void)offset;
	(void)iov;
	(void)iovlen;
	d->posix_errno = EROFS;
	return (-1);
}

int
efile_seek(efile_data_t *d, enum efile_seek_t seek, Sint64 offset, Sint64 *new_position)
{
	erx_efile_t *handle = (erx_efile_t *)d;
	Sint64 base, position;

	switch (seek) {
	case EFILE_SEEK_BOF:
		base = 0;
		break;
	case EFILE_SEEK_CUR:
		base = handle->position;
		break;
	case EFILE_SEEK_EOF:
		base = (Sint64)release_fs.files[handle->file].size;
		break;
	default:
		d->posix_errno = EINVAL;
		return (0);
	}
	if (__builtin_add_overflow(base, offset, &position) || position < 0) {
		d->posix_errno = EINVAL;
		return (0);
	}
	handle->position = position;
	*new_position = position;
	return (1);
}

/* Nothing of a read-only file is ever pending. */
int
efile_sync(efile_data_t *d, int data_only)
{
	(void)d;
	(void)data_only;
	return (1);
}

int
efile_advise(efile_data_t *d, Sint64 offset, Sint64 length, enum efile_advise_t advise)
{
	(void)offset;
	(void)length;
	(void)advise;
	d->posix_errno = ENOTSUP;
	return (0);
}

int
efile_allocate(efile_data_t *d, Sint64 offset, Sint64 length)
{
	(void)offset;
	(void)length;
	d->posix_errno = ENOTSUP;
	return (0);
}

int
efile_truncate(efile_data_t *d)
{
	d->posix_errno = EROFS;
	return (0);
}

/* An archive records no owner, group or time, and a build is reproducible. */
static void
erx_fill_info(erx_release_fs_kind_t kind, uint64_t size, efile_fileinfo_t *result)
{
	sys_memzero(result, sizeof(*result));
	result->size = (Sint64)size;
	result->type = kind == ERX_RELEASE_FS_FILE ?
	    EFILE_FILETYPE_REGULAR : EFILE_FILETYPE_DIRECTORY;
	result->mode = kind == ERX_RELEASE_FS_FILE ?
	    ERX_FILE_MODE : ERX_DIRECTORY_MODE;
	result->access = EFILE_ACCESS_READ;
	result->links = 1;
}

posix_errno_t
efile_read_info(const efile_path_t *path, int follow_links, efile_fileinfo_t *result)
{
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	uint32_t file;

	(void)follow_links;
	error = erx_find_existing(path, &kind, &file);
	if (error != 0)
		return (error);
	erx_fill_info(kind, kind == ERX_RELEASE_FS_FILE ?
	    release_fs.files[file].size : 0, result);
	return (0);
}

posix_errno_t
efile_read_handle_info(efile_data_t *d, efile_fileinfo_t *result)
{
	erx_efile_t *handle = (erx_efile_t *)d;

	erx_fill_info(ERX_RELEASE_FS_FILE, release_fs.files[handle->file].size, result);
	return (0);
}

posix_errno_t
efile_set_time(const efile_path_t *path, Sint64 a_time, Sint64 m_time, Sint64 c_time)
{
	(void)a_time;
	(void)m_time;
	(void)c_time;
	(void)path;
	return (EROFS);
}

posix_errno_t
efile_set_permissions(const efile_path_t *path, Uint32 permissions)
{
	(void)permissions;
	(void)path;
	return (EROFS);
}

posix_errno_t
efile_set_owner(const efile_path_t *path, Sint32 owner, Sint32 group)
{
	(void)owner;
	(void)group;
	(void)path;
	return (EROFS);
}

/* The provider has no links. */
posix_errno_t
efile_read_link(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result)
{
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	uint32_t file;

	(void)env;
	(void)result;
	error = erx_find_existing(path, &kind, &file);
	return (error != 0 ? error : EINVAL);
}

posix_errno_t
efile_list_dir(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result)
{
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	ERL_NIF_TERM list, term;
	const uint8_t *name;
	size_t name_length;
	uint32_t cursor, file;

	error = erx_find_existing(path, &kind, &file);
	if (error != 0)
		return (error);
	if (kind == ERX_RELEASE_FS_FILE)
		return (ENOTDIR);
	list = enif_make_list(env, 0);
	cursor = erx_release_fs_list_start(&release_fs, (const uint8_t *)path->result.res_names,
	    path->result.res_names_length);
	while (erx_release_fs_list_next(&release_fs, (const uint8_t *)path->result.res_names,
	    path->result.res_names_length, &cursor, &name, &name_length)) {
		memcpy(enif_make_new_binary(env, name_length, &term), name, name_length);
		list = enif_make_list_cell(env, term, list);
	}
	*result = list;
	return (0);
}

/*
 * The release is read-only, and marshalling has resolved every path these are
 * given, so each meets EROFS.
 */
posix_errno_t
efile_rename(const efile_path_t *old_path, const efile_path_t *new_path)
{
	(void)old_path;
	(void)new_path;
	return (EROFS);
}

posix_errno_t
efile_make_hard_link(const efile_path_t *existing_path, const efile_path_t *new_path)
{
	(void)existing_path;
	(void)new_path;
	return (EROFS);
}

/* A symbolic link's target is its text, which marshalling does not resolve. */
posix_errno_t
efile_make_soft_link(const efile_path_t *existing_path, const efile_path_t *new_path)
{
	(void)existing_path;
	(void)new_path;
	return (EROFS);
}

posix_errno_t
efile_make_dir(const efile_path_t *path)
{
	(void)path;
	return (EROFS);
}

posix_errno_t
efile_del_file(const efile_path_t *path)
{
	(void)path;
	return (EROFS);
}

posix_errno_t
efile_del_dir(const efile_path_t *path)
{
	(void)path;
	return (EROFS);
}

posix_errno_t
efile_get_cwd(ErlNifEnv *env, ERL_NIF_TERM *result)
{
	size_t length;

	enif_rwlock_rlock(ns_lock);
	length = strlen(name_space.cwd);
	memcpy(enif_make_new_binary(env, length, result), name_space.cwd, length);
	enif_rwlock_runlock(ns_lock);
	return (0);
}

posix_errno_t
efile_set_cwd(const efile_path_t *path)
{
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	uint32_t file;

	error = erx_find_existing(path, &kind, &file);
	if (error != 0)
		return (error);
	if (kind == ERX_RELEASE_FS_FILE)
		return (ENOTDIR);
	enif_rwlock_rwlock(ns_lock);
	memcpy(name_space.cwd, path->result.res_path, path->result.res_path_length + 1);
	enif_rwlock_rwunlock(ns_lock);
	return (0);
}

posix_errno_t
efile_get_device_cwd(ErlNifEnv *env, int device_index, ERL_NIF_TERM *result)
{
	(void)env;
	(void)device_index;
	(void)result;
	return (ENOTSUP);
}

posix_errno_t
efile_altname(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result)
{
	(void)env;
	(void)path;
	(void)result;
	return (ENOTSUP);
}
