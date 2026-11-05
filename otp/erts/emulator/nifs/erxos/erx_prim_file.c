/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * prim_file's platform layer over the namespace (design-runtime.md, Files). Every
 * path passes erx_ns_resolve; the one provider here is the release file system,
 * read-only, which the namespace mounts at `/`. A handle holds a file of the
 * release and a position, under prim_file_nif.c's per-file state, and no file
 * descriptor exists anywhere in the layer.
 *
 * The namespace's table and the table of names are built once, when the NIF loads,
 * and are immutable afterwards, so readers take no lock. Only the working directory
 * changes, under cwd_lock, and the flags of file_checked, which guard no data.
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

static erx_ns_t		name_space;
static ErlNifRWLock	*cwd_lock;
static erx_release_fs_t	release_fs;
/*
 * Per file, whether it has passed erx_release_check. Only ever goes from 0 to 1 and
 * guards no data, so two opens racing hash twice and nothing worse.
 */
static erts_atomic32_t	*file_checked;

static int erx_build_table(void);
static posix_errno_t erx_resolve(const efile_path_t *, erx_ns_result_t *);
static posix_errno_t erx_find(const efile_path_t *, erx_ns_result_t *,
    erx_release_fs_kind_t *, uint32_t *);
static posix_errno_t erx_find_existing(const efile_path_t *, erx_ns_result_t *,
    erx_release_fs_kind_t *, uint32_t *);
static posix_errno_t erx_read_only(const efile_path_t *);
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
efile_load(void)
{
	name_space.count = 1;
	name_space.mounts[0].kind = ERX_NS_RELEASE;
	name_space.mounts[0].point[0] = '/';
	name_space.mounts[0].root[0] = '/';
	name_space.cwd[0] = '/';
	cwd_lock = enif_rwlock_create("erx_prim_file_cwd");
	if (cwd_lock == NULL)
		return (-1);
	return (erx_build_table());
}

posix_errno_t
efile_marshal_path(ErlNifEnv *env, ERL_NIF_TERM path, efile_path_t *result)
{
	if (!enif_inspect_binary(env, path, result))
		return (EINVAL);
	if (result->size == 0 || result->data[result->size - 1] != '\0')
		return (EINVAL);
	return (0);
}

/* A marshalled path ends in its one NUL, which the resolver does not see. */
static posix_errno_t
erx_resolve(const efile_path_t *path, erx_ns_result_t *out)
{
	erx_ns_status_t status;

	enif_rwlock_rlock(cwd_lock);
	status = erx_ns_resolve(&name_space, path->data, path->size - 1, out);
	enif_rwlock_runlock(cwd_lock);
	switch (status) {
	case ERX_NS_OK:
		return (0);
	case ERX_NS_EINVAL:
		return (EINVAL);
	case ERX_NS_ENAMETOOLONG:
		return (ENAMETOOLONG);
	case ERX_NS_ENOENT:
		return (ENOENT);
	}
	return (EINVAL);
}

/* New kinds of file are new rows here; the callers below do not move. */
static posix_errno_t
erx_find(const efile_path_t *path, erx_ns_result_t *out,
    erx_release_fs_kind_t *kind, uint32_t *file)
{
	posix_errno_t error;

	error = erx_resolve(path, out);
	if (error != 0)
		return (error);
	if (out->res_mount == NULL || out->res_mount->kind != ERX_NS_RELEASE)
		return (ENOTSUP);
	*kind = erx_release_fs_lookup(&release_fs, (const uint8_t *)out->res_names,
	    out->res_names_length, file);
	return (0);
}

static posix_errno_t
erx_find_existing(const efile_path_t *path, erx_ns_result_t *out,
    erx_release_fs_kind_t *kind, uint32_t *file)
{
	posix_errno_t error;

	error = erx_find(path, out, kind, file);
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

/* A path's own error comes first; any other path meets a read-only tree. */
static posix_errno_t
erx_read_only(const efile_path_t *path)
{
	erx_ns_result_t out;
	posix_errno_t error;

	error = erx_resolve(path, &out);
	return (error != 0 ? error : EROFS);
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
	erx_ns_result_t out;
	erx_release_fs_kind_t kind;
	erx_efile_t *handle;
	posix_errno_t error;
	uint32_t file;

	*d = NULL;
	if ((modes & (EFILE_MODE_WRITE | EFILE_MODE_APPEND | EFILE_MODE_EXCLUSIVE)) != 0)
		return (erx_read_only(path));
	error = erx_find_existing(path, &out, &kind, &file);
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
	erx_ns_result_t out;
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	uint32_t file;

	(void)follow_links;
	error = erx_find_existing(path, &out, &kind, &file);
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
	return (erx_read_only(path));
}

posix_errno_t
efile_set_permissions(const efile_path_t *path, Uint32 permissions)
{
	(void)permissions;
	return (erx_read_only(path));
}

posix_errno_t
efile_set_owner(const efile_path_t *path, Sint32 owner, Sint32 group)
{
	(void)owner;
	(void)group;
	return (erx_read_only(path));
}

/* The provider has no links. */
posix_errno_t
efile_read_link(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result)
{
	erx_ns_result_t out;
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	uint32_t file;

	(void)env;
	(void)result;
	error = erx_find_existing(path, &out, &kind, &file);
	return (error != 0 ? error : EINVAL);
}

posix_errno_t
efile_list_dir(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result)
{
	erx_ns_result_t out;
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	ERL_NIF_TERM list, term;
	const uint8_t *name;
	size_t name_length;
	uint32_t cursor, file;

	error = erx_find_existing(path, &out, &kind, &file);
	if (error != 0)
		return (error);
	if (kind == ERX_RELEASE_FS_FILE)
		return (ENOTDIR);
	list = enif_make_list(env, 0);
	cursor = erx_release_fs_list_start(&release_fs, (const uint8_t *)out.res_names,
	    out.res_names_length);
	while (erx_release_fs_list_next(&release_fs, (const uint8_t *)out.res_names,
	    out.res_names_length, &cursor, &name, &name_length)) {
		memcpy(enif_make_new_binary(env, name_length, &term), name, name_length);
		list = enif_make_list_cell(env, term, list);
	}
	*result = list;
	return (0);
}

posix_errno_t
efile_rename(const efile_path_t *old_path, const efile_path_t *new_path)
{
	erx_ns_result_t out;
	posix_errno_t error;

	error = erx_resolve(old_path, &out);
	return (error != 0 ? error : erx_read_only(new_path));
}

posix_errno_t
efile_make_hard_link(const efile_path_t *existing_path, const efile_path_t *new_path)
{
	erx_ns_result_t out;
	posix_errno_t error;

	error = erx_resolve(existing_path, &out);
	return (error != 0 ? error : erx_read_only(new_path));
}

/* A symbolic link's target is its text, which no path check applies to. */
posix_errno_t
efile_make_soft_link(const efile_path_t *existing_path, const efile_path_t *new_path)
{
	(void)existing_path;
	return (erx_read_only(new_path));
}

posix_errno_t
efile_make_dir(const efile_path_t *path)
{
	return (erx_read_only(path));
}

posix_errno_t
efile_del_file(const efile_path_t *path)
{
	return (erx_read_only(path));
}

posix_errno_t
efile_del_dir(const efile_path_t *path)
{
	return (erx_read_only(path));
}

posix_errno_t
efile_get_cwd(ErlNifEnv *env, ERL_NIF_TERM *result)
{
	size_t length;

	enif_rwlock_rlock(cwd_lock);
	length = strlen(name_space.cwd);
	memcpy(enif_make_new_binary(env, length, result), name_space.cwd, length);
	enif_rwlock_runlock(cwd_lock);
	return (0);
}

posix_errno_t
efile_set_cwd(const efile_path_t *path)
{
	erx_ns_result_t out;
	erx_release_fs_kind_t kind;
	posix_errno_t error;
	uint32_t file;

	error = erx_find_existing(path, &out, &kind, &file);
	if (error != 0)
		return (error);
	if (kind == ERX_RELEASE_FS_FILE)
		return (ENOTDIR);
	enif_rwlock_rwlock(cwd_lock);
	memcpy(name_space.cwd, out.res_path, out.res_path_length + 1);
	enif_rwlock_rwunlock(cwd_lock);
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
