/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The staged swap of prim_file's platform layer. Stock's unix_prim_file.c is linked
 * beside erx_prim_file.c, and a run that names an archive with ERX_RELEASE_ARCHIVE
 * gets the latter, chosen once when the NIF loads. The makefile builds the two with
 * their efile_ names renamed to stock_efile_ and release_efile_. TODO.md says what
 * removes this file.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "erl_nif.h"
#include "sys.h"

#include "prim_file_nif.h"

#include <stdbool.h>

#include "liberx/backend/hosted/release.h"

static bool use_release;

int release_efile_load(void);

int
efile_load(void)
{
	const char *reason;

	switch (erx_hosted_release_map(&reason)) {
	case ERX_HOSTED_RELEASE_NONE:
		return (0);
	case ERX_HOSTED_RELEASE_MAPPED:
		use_release = true;
		return (release_efile_load());
	case ERX_HOSTED_RELEASE_REFUSED:
		break;
	}
	enif_fprintf(stderr, "prim_file: boot archive refused: %s\n", reason);
	return (-1);
}

/* Each row: the result, the name after efile_, the parameters, the arguments. */
#define ERX_EFILE_LAYER(ROW) \
	ROW(posix_errno_t, marshal_path, (ErlNifEnv *env, ERL_NIF_TERM path, efile_path_t *result), (env, path, result)) \
	ROW(ERL_NIF_TERM, get_handle, (ErlNifEnv *env, efile_data_t *d), (env, d)) \
	ROW(posix_errno_t, dup_handle, (ErlNifEnv *env, efile_data_t *d, ErlNifEvent *handle), (env, d, handle)) \
	ROW(Sint64, readv, (efile_data_t *d, SysIOVec *iov, int iovlen), (d, iov, iovlen)) \
	ROW(Sint64, writev, (efile_data_t *d, SysIOVec *iov, int iovlen), (d, iov, iovlen)) \
	ROW(Sint64, preadv, (efile_data_t *d, Sint64 offset, SysIOVec *iov, int iovlen), (d, offset, iov, iovlen)) \
	ROW(Sint64, pwritev, (efile_data_t *d, Sint64 offset, SysIOVec *iov, int iovlen), (d, offset, iov, iovlen)) \
	ROW(int, seek, (efile_data_t *d, enum efile_seek_t seek, Sint64 offset, Sint64 *new_position), (d, seek, offset, new_position)) \
	ROW(int, sync, (efile_data_t *d, int data_only), (d, data_only)) \
	ROW(int, advise, (efile_data_t *d, Sint64 offset, Sint64 length, enum efile_advise_t advise), (d, offset, length, advise)) \
	ROW(int, allocate, (efile_data_t *d, Sint64 offset, Sint64 length), (d, offset, length)) \
	ROW(int, truncate, (efile_data_t *d), (d)) \
	ROW(posix_errno_t, open, (const efile_path_t *path, enum efile_modes_t modes, ErlNifResourceType *nif_type, efile_data_t **d), (path, modes, nif_type, d)) \
	ROW(posix_errno_t, from_fd, (int fd, ErlNifResourceType *nif_type, efile_data_t **d), (fd, nif_type, d)) \
	ROW(int, close, (efile_data_t *d, posix_errno_t *error), (d, error)) \
	ROW(posix_errno_t, read_info, (const efile_path_t *path, int follow_link, efile_fileinfo_t *result), (path, follow_link, result)) \
	ROW(posix_errno_t, read_handle_info, (efile_data_t *d, efile_fileinfo_t *result), (d, result)) \
	ROW(posix_errno_t, set_time, (const efile_path_t *path, Sint64 a_time, Sint64 m_time, Sint64 c_time), (path, a_time, m_time, c_time)) \
	ROW(posix_errno_t, set_permissions, (const efile_path_t *path, Uint32 permissions), (path, permissions)) \
	ROW(posix_errno_t, set_owner, (const efile_path_t *path, Sint32 owner, Sint32 group), (path, owner, group)) \
	ROW(posix_errno_t, read_link, (ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result), (env, path, result)) \
	ROW(posix_errno_t, list_dir, (ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result), (env, path, result)) \
	ROW(posix_errno_t, rename, (const efile_path_t *old_path, const efile_path_t *new_path), (old_path, new_path)) \
	ROW(posix_errno_t, make_hard_link, (const efile_path_t *existing_path, const efile_path_t *new_path), (existing_path, new_path)) \
	ROW(posix_errno_t, make_soft_link, (const efile_path_t *existing_path, const efile_path_t *new_path), (existing_path, new_path)) \
	ROW(posix_errno_t, make_dir, (const efile_path_t *path), (path)) \
	ROW(posix_errno_t, del_file, (const efile_path_t *path), (path)) \
	ROW(posix_errno_t, del_dir, (const efile_path_t *path), (path)) \
	ROW(posix_errno_t, get_cwd, (ErlNifEnv *env, ERL_NIF_TERM *result), (env, result)) \
	ROW(posix_errno_t, set_cwd, (const efile_path_t *path), (path)) \
	ROW(posix_errno_t, get_device_cwd, (ErlNifEnv *env, int device_index, ERL_NIF_TERM *result), (env, device_index, result)) \
	ROW(posix_errno_t, altname, (ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result), (env, path, result))

#define ERX_EFILE_DISPATCH(result, name, parameters, arguments) \
	result stock_efile_##name parameters; \
	result release_efile_##name parameters; \
	result efile_##name parameters \
	{ \
		return (use_release ? release_efile_##name arguments : \
		    stock_efile_##name arguments); \
	}

ERX_EFILE_LAYER(ERX_EFILE_DISPATCH)
