/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * prim_file's platform layer for the release file system (design-runtime.md,
 * Files; design-files.md, Erlang clients). prim_file finds where a path lies in
 * Erlang, over the namespace's persistent term, and calls a NIF here only for a
 * path on the release, handing it the path's names from the release's top as a
 * list of binaries. Any process can call the NIFs with any term, so each list
 * passes erx_release_fs_add_name, name by name, before the release's core sees
 * it, and a list it refuses answers einval. release_walk_nif(Names) answers the
 * kind of each name as erx_path's walk callback does. A handle holds a file of
 * the release and a position, under prim_file_nif.c's per-file state, and no
 * file descriptor exists anywhere in the layer.
 *
 * Two pieces of the runtime's state live here as well. The working directory is
 * a place, `/` or `/a/b`, which prim_file:set_cwd/1 alone stores, having
 * checked it, and every relative path reads; one reader-writer lock guards its
 * bytes. The fid counter (design-files.md, Version and attach) is one 64-bit
 * atomic, which a draw adds one to and keeps the low 32 bits of, drawing again
 * for NOFID, so no process allocates fids.
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

#include "erx/abi.h"
#include "erx/release.h"
#include "erx/release_fs.h"

#include "erx_fid.h"

/* As stock reports them: st_mode, with the type's bits. */
#define ERX_FILE_MODE		(S_IFREG | 0444)
#define ERX_DIRECTORY_MODE	(S_IFDIR | 0555)

/*
 * An open file or directory of the release. file indexes release_fs.files only when
 * kind is ERX_RELEASE_FS_FILE: a directory, opened with [directory], has no entry of
 * its own, and every read of it is EISDIR.
 */
typedef struct erx_efile {
	efile_data_t		common;
	erx_release_fs_kind_t	kind;
	uint32_t		file;
	Sint64			position;
} erx_efile_t;

/* The working directory, NUL-terminated, under cwd_lock. */
static char		cwd[ERX_PATH_MAX];
static ErlNifRWLock	*cwd_lock;
static erts_atomic64_t	fid_counter;
static erx_release_fs_t	release_fs;
/*
 * Per file, whether it has passed erx_release_check. Only ever goes from 0 to 1 and
 * guards no data, so two opens racing hash twice and nothing worse.
 */
static erts_atomic32_t	*file_checked;

static int erx_build_table(void);
static ERL_NIF_TERM erx_error(ErlNifEnv *, const char *);
static posix_errno_t erx_find(const efile_path_t *, erx_release_fs_kind_t *,
    uint32_t *);
static posix_errno_t erx_find_existing(const efile_path_t *,
    erx_release_fs_kind_t *, uint32_t *);
static posix_errno_t erx_write_refusal(const efile_path_t *, enum efile_modes_t);
static Sint64 erx_copy_out(erx_efile_t *, Sint64, SysIOVec *, int);
static uint64_t erx_handle_size(const erx_efile_t *);
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
	(void)env;
	cwd[0] = '/';
	erts_atomic64_init_nob(&fid_counter, 0);
	cwd_lock = enif_rwlock_create("erx_prim_file_cwd");
	if (cwd_lock == NULL)
		return (-1);
	return (erx_build_table());
}

static ERL_NIF_TERM
erx_error(ErlNifEnv *env, const char *reason)
{
	return (enif_make_tuple2(env, enif_make_atom(env, "error"),
	    enif_make_atom(env, reason)));
}

/*
 * A path on the release: its names from the release's top, a proper list of
 * binaries, each checked as it is added. Anything else is EINVAL.
 */
posix_errno_t
efile_marshal_path(ErlNifEnv *env, ERL_NIF_TERM path, efile_path_t *result)
{
	ERL_NIF_TERM name, rest;
	ErlNifBinary bytes;

	result->count = 0;
	result->length = 0;
	rest = path;
	while (enif_get_list_cell(env, rest, &name, &rest)) {
		if (!enif_inspect_binary(env, name, &bytes) ||
		    !erx_release_fs_add_name(result, bytes.data, bytes.size))
			return (EINVAL);
	}
	return (enif_is_empty_list(env, rest) ? 0 : EINVAL);
}

/* A symbolic link's text, which names nothing here: a binary ending in its one NUL. */
posix_errno_t
efile_marshal_text(ErlNifEnv *env, ERL_NIF_TERM text, efile_path_t *result)
{
	ErlNifBinary bytes;

	result->count = 0;
	result->length = 0;
	if (!enif_inspect_binary(env, text, &bytes) || bytes.size == 0 ||
	    bytes.data[bytes.size - 1] != '\0')
		return (EINVAL);
	return (0);
}

/*
 * prim_file:release_walk_nif(Names): the walk erx_path asks the release for,
 * {Kinds, End}. Kinds holds `directory` for each leading name that is one, then
 * `other` for a file among the names; End is {error, enoent} at a missing name
 * and ok otherwise. A list the decoder refuses answers {error, einval}.
 */
ERL_NIF_TERM
efile_release_walk_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	efile_path_t path;
	erx_release_fs_kind_t stop;
	ERL_NIF_TERM kinds, end, directory;
	uint32_t passed;

	if (argc != 1 || efile_marshal_path(env, argv[0], &path) != 0)
		return (erx_error(env, "einval"));
	passed = erx_release_fs_walk(&release_fs, &path, &stop);
	kinds = enif_make_list(env, 0);
	if (stop == ERX_RELEASE_FS_FILE)
		kinds = enif_make_list_cell(env, enif_make_atom(env, "other"), kinds);
	directory = enif_make_atom(env, "directory");
	for (uint32_t index = 0; index < passed; index++)
		kinds = enif_make_list_cell(env, directory, kinds);
	end = stop == ERX_RELEASE_FS_MISSING ? erx_error(env, "enoent") :
	    enif_make_atom(env, "ok");
	return (enif_make_tuple2(env, kinds, end));
}

/* prim_file:erx_fid_nif(): one draw of the runtime's fid counter. */
ERL_NIF_TERM
efile_fid_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uint32_t fid;

	(void)argc;
	(void)argv;
	while (!erx_fid_of((uint64_t)erts_atomic64_inc_read_nob(&fid_counter), &fid))
		continue;
	return (enif_make_uint(env, fid));
}

/*
 * prim_file:erx_set_cwd_nif(Place): makes Place the working directory. Only
 * prim_file:set_cwd/1 calls it, a source check holds it to that one caller, and
 * set_cwd/1 has checked that Place is a place (design-files.md, Erlang clients).
 * What is checked here is only what keeps the store in bounds: a binary shorter
 * than the store, with room for its NUL. Nothing about what lies there is
 * checked: the working directory is a path, resolved again at each use, so a
 * mount change between set_cwd's check and this store leaves the state the same
 * change would leave just after it.
 */
ERL_NIF_TERM
efile_ns_set_cwd_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary place;

	if (argc != 1 || !enif_inspect_binary(env, argv[0], &place) ||
	    place.size == 0 || place.size >= sizeof(cwd))
		return (erx_error(env, "einval"));
	enif_rwlock_rwlock(cwd_lock);
	memcpy(cwd, place.data, place.size);
	cwd[place.size] = '\0';
	enif_rwlock_rwunlock(cwd_lock);
	return (enif_make_atom(env, "ok"));
}

/* prim_file:erx_tmp_limit_nif(): the cap of the domain's /tmp, from its startup limits. */
ERL_NIF_TERM
efile_tmp_limit_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	(void)argv;
	return (enif_make_uint64(env, erx_runtime_tmp_limit()));
}

/* New kinds of file are new rows here; the callers below do not move. */
static posix_errno_t
erx_find(const efile_path_t *path, erx_release_fs_kind_t *kind, uint32_t *file)
{
	*kind = erx_release_fs_lookup(&release_fs, path->bytes, path->length, file);
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

/*
 * The refusal of an open that writes, in the order of open(2) with O_CREAT: the walk
 * to the last name first (ENOENT, ENOTDIR), then an exclusive open of a name that
 * exists (EEXIST), then a directory (EISDIR), and only then the read-only file system
 * (EROFS), for a file or for a missing name whose directory exists.
 */
static posix_errno_t
erx_write_refusal(const efile_path_t *path, enum efile_modes_t modes)
{
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	size_t parent_length;
	uint32_t file;

	error = erx_find(path, &kind, &file);
	if (error != 0)
		return (error);
	switch (kind) {
	case ERX_RELEASE_FS_FILE:
	case ERX_RELEASE_FS_DIRECTORY:
		if ((modes & EFILE_MODE_EXCLUSIVE) != 0)
			return (EEXIST);
		return (kind == ERX_RELEASE_FS_DIRECTORY ? EISDIR : EROFS);
	case ERX_RELEASE_FS_NOT_DIRECTORY:
		return (ENOTDIR);
	case ERX_RELEASE_FS_MISSING:
		break;
	}
	/*
	 * The missing name's directory: the names before its last "/", or the top, which
	 * is always a directory. A file on the way would have answered NOT_DIRECTORY.
	 */
	parent_length = path->length;
	while (parent_length > 0 && path->bytes[parent_length - 1] != '/')
		parent_length--;
	if (parent_length > 0)
		parent_length--;	/* the "/" itself */
	kind = erx_release_fs_lookup(&release_fs, path->bytes,
	    parent_length, &file);
	return (kind == ERX_RELEASE_FS_DIRECTORY ? EROFS : ENOENT);
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
		return (erx_write_refusal(path, modes));
	error = erx_find_existing(path, &kind, &file);
	if (error != 0)
		return (error);
	if (kind == ERX_RELEASE_FS_DIRECTORY && (modes & EFILE_MODE_DIRECTORY) == 0)
		return (EISDIR);
	if (kind == ERX_RELEASE_FS_FILE && (modes & EFILE_MODE_DIRECTORY) != 0)
		return (ENOTDIR);
	if (kind == ERX_RELEASE_FS_FILE) {
		error = erx_check_file(file);
		if (error != 0)
			return (error);
	}
	handle = (erx_efile_t *)enif_alloc_resource(nif_type, sizeof(*handle));
	handle->kind = kind;
	handle->file = kind == ERX_RELEASE_FS_FILE ? file : 0;
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

/*
 * offset is at least zero; past the end there is nothing to copy. A directory reads
 * as stock's read(2) of one answers: EISDIR.
 */
static Sint64
erx_copy_out(erx_efile_t *handle, Sint64 offset, SysIOVec *iov, int iovlen)
{
	const erx_release_fs_file_t *entry;
	const uint8_t *data;
	uint64_t remaining;
	size_t count;
	Sint64 total;

	if (handle->kind != ERX_RELEASE_FS_FILE) {
		handle->common.posix_errno = EISDIR;
		return (-1);
	}
	entry = &release_fs.files[handle->file];
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

	count = erx_copy_out(handle, handle->position, iov, iovlen);
	if (count > 0)
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
	return (erx_copy_out(handle, offset, iov, iovlen));
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

/* A directory's size is 0, as read_file_info answers. */
static uint64_t
erx_handle_size(const erx_efile_t *handle)
{
	return (handle->kind == ERX_RELEASE_FS_FILE ? release_fs.files[handle->file].size : 0);
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
		base = (Sint64)erx_handle_size(handle);
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

/*
 * Advice is only a recommendation, and prim_file_nif.c has checked its arguments: ok,
 * as stock's efile_advise answers without posix_fadvise.
 */
int
efile_advise(efile_data_t *d, Sint64 offset, Sint64 length, enum efile_advise_t advise)
{
	(void)d;
	(void)offset;
	(void)length;
	(void)advise;
	return (1);
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

	erx_fill_info(handle->kind, erx_handle_size(handle), result);
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
	cursor = erx_release_fs_list_start(&release_fs, path->bytes,
	    path->length);
	while (erx_release_fs_list_next(&release_fs, path->bytes,
	    path->length, &cursor, &name, &name_length)) {
		memcpy(enif_make_new_binary(env, name_length, &term), name, name_length);
		list = enif_make_list_cell(env, term, list);
	}
	*result = list;
	return (0);
}

/*
 * The release is read-only, and prim_file has found every path these are given
 * on it, so each meets EROFS; prim_file turns a rename's EROFS for a source
 * written `/` into einval (design-files.md, Errors, step 1).
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

/* A symbolic link's target is its text, which names nothing here. */
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

	enif_rwlock_rlock(cwd_lock);
	length = strlen(cwd);
	memcpy(enif_make_new_binary(env, length, result), cwd, length);
	enif_rwlock_runlock(cwd_lock);
	return (0);
}

/* prim_file:set_cwd/1 walks the place itself and stores it with erx_set_cwd_nif/1. */
posix_errno_t
efile_set_cwd(const efile_path_t *path)
{
	(void)path;
	return (ENOTSUP);
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
