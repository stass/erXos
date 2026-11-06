/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * littlefs, the stopgap read-write file system, as a NIF of the system
 * domain (docs/design-stopgap.md#littlefs-in-the-system-domain).
 *
 * One volume is one resource that holds littlefs's state, its buffers and a
 * fixed table of open-file slots, so nothing littlefs points at is ever freed
 * by the garbage collector while littlefs still links it. Only the volume's
 * worker process calls the operations, on a dirty I/O scheduler, one at a
 * time; a second caller while one runs is refused with `ebusy`.
 *
 * littlefs's block callbacks do no I/O here. Each read, program or sync
 * becomes one block request: a resource holding a state, a result and a
 * buffer, posted to the volume's owner process as
 * `{erx_lfs_block, Op, Sector, Count, Req}`. The callback then waits on the
 * request's condition until the owner calls `complete/2` (a normal, not a
 * dirty, NIF) or the deadline passes. The owner serves the request through
 * the block service on normal schedulers and never waits for the worker, so
 * the one dirty thread an operation holds waits for nothing that needs a
 * second dirty thread: that is the deadlock argument.
 *
 * Any block failure (an error answer, a deadline, an owner that is gone)
 * marks the volume broken: the failing operation and every later one answer
 * `{error, eio}` and nothing is retried, as the design requires.
 */

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <time.h>

/* Linked into ERTS; the host test builds it as a loadable library instead. */
#ifndef ERX_LITTLEFS_LOADABLE
#define STATIC_ERLANG_NIF 1
#endif
#include "erl_nif.h"
#include "lfs.h"

#include "erx_littlefs.h"

/* Request states: the owner moves PENDING to DONE, the deadline to ENDED. */
enum req_state {
	REQ_PENDING,
	REQ_DONE,
	REQ_ENDED,
};

enum req_op {
	REQ_READ,
	REQ_WRITE,
	REQ_FLUSH,
};

typedef struct erx_lfs_req {
	pthread_mutex_t lock;
	pthread_cond_t cond;
	enum req_state state;
	enum req_op op;
	int ok;
	size_t size;
	uint8_t buf[];
} erx_lfs_req_t;

typedef struct erx_lfs_slot {
	int used;
	lfs_file_t file;
	struct lfs_file_config cfg;
	uint8_t cache[ERX_LFS_CACHE_SIZE];
} erx_lfs_slot_t;

typedef struct erx_lfs_vol {
	lfs_t lfs;
	struct lfs_config cfg;
	ErlNifPid owner;
	/* The environment of the operation running, for enif_send. */
	ErlNifEnv *env;
	uint32_t deadline_ms;
	atomic_flag busy;
	int mounted;
	int broken;
	uint8_t read_buf[ERX_LFS_CACHE_SIZE];
	uint8_t prog_buf[ERX_LFS_CACHE_SIZE];
	uint8_t lookahead_buf[ERX_LFS_LOOKAHEAD_SIZE];
	erx_lfs_slot_t slots[ERX_LFS_SLOTS];
} erx_lfs_vol_t;

static ErlNifResourceType *vol_type;
static ErlNifResourceType *req_type;

static ERL_NIF_TERM atom_ok, atom_error, atom_block, atom_read, atom_write,
    atom_flush, atom_file, atom_directory, atom_late;

static ERL_NIF_TERM
mk_atom(ErlNifEnv *env, const char *name)
{
	ERL_NIF_TERM atom;

	if (enif_make_existing_atom(env, name, &atom, ERL_NIF_LATIN1))
		return (atom);
	return (enif_make_atom(env, name));
}

static ERL_NIF_TERM
error_posix(ErlNifEnv *env, const char *posix)
{
	return (enif_make_tuple2(env, atom_error, mk_atom(env, posix)));
}

/* littlefs's errors as POSIX names; anything unknown is eio. */
static const char *
lfs_posix(int err)
{
	switch (err) {
	case LFS_ERR_NOENT:
		return ("enoent");
	case LFS_ERR_EXIST:
		return ("eexist");
	case LFS_ERR_NOTDIR:
		return ("enotdir");
	case LFS_ERR_ISDIR:
		return ("eisdir");
	case LFS_ERR_NOTEMPTY:
		return ("enotempty");
	case LFS_ERR_BADF:
		return ("ebadf");
	case LFS_ERR_FBIG:
		return ("efbig");
	case LFS_ERR_INVAL:
		return ("einval");
	case LFS_ERR_NOSPC:
		return ("enospc");
	case LFS_ERR_NOMEM:
		return ("enomem");
	case LFS_ERR_NOATTR:
		return ("enodata");
	case LFS_ERR_NAMETOOLONG:
		return ("enametoolong");
	default:
		return ("eio");
	}
}

/* A volume that met a block failure answers eio whatever littlefs said. */
static ERL_NIF_TERM
lfs_error(ErlNifEnv *env, const erx_lfs_vol_t *vol, int err)
{
	return (error_posix(env, vol->broken ? "eio" : lfs_posix(err)));
}

/* ------------------------------------------------------------------------
 * Block requests
 * ------------------------------------------------------------------------ */

static void
req_dtor(ErlNifEnv *env, void *obj)
{
	erx_lfs_req_t *req = obj;

	(void)env;
	pthread_cond_destroy(&req->cond);
	pthread_mutex_destroy(&req->lock);
}

static void
deadline_after(struct timespec *ts, uint32_t ms)
{
	clock_gettime(CLOCK_REALTIME, ts);
	ts->tv_sec += ms / 1000;
	ts->tv_nsec += (long)(ms % 1000) * 1000000L;
	if (ts->tv_nsec >= 1000000000L) {
		ts->tv_sec += 1;
		ts->tv_nsec -= 1000000000L;
	}
}

/*
 * One block request: post it to the owner and wait for its answer or the
 * deadline. The callback and the owner's term each hold a reference to the
 * request, so a late complete/2 writes into memory that is still alive.
 */
static int
block_request(const struct lfs_config *c, enum req_op op, lfs_block_t block,
    lfs_off_t off, void *buffer, lfs_size_t size)
{
	erx_lfs_vol_t *vol = c->context;
	erx_lfs_req_t *req;
	ErlNifEnv *msg_env;
	ERL_NIF_TERM msg, op_atom;
	struct timespec deadline;
	uint64_t byte;
	enum req_state state;
	int ok, sent, rc;

	if (vol->broken || vol->env == NULL)
		return (LFS_ERR_IO);
	/* littlefs keeps block < block_count and off + size <= block_size. */
	byte = (uint64_t)block * c->block_size + off;
	if (op != REQ_FLUSH && (block >= c->block_count ||
	    size > c->block_size || off > c->block_size - size ||
	    byte % ERX_LFS_SECTOR_SIZE != 0 ||
	    size % ERX_LFS_SECTOR_SIZE != 0 || size == 0)) {
		vol->broken = 1;
		return (LFS_ERR_IO);
	}
	if (op == REQ_FLUSH)
		size = 0;

	req = enif_alloc_resource(req_type, sizeof(*req) + size);
	if (req == NULL) {
		vol->broken = 1;
		return (LFS_ERR_IO);
	}
	pthread_mutex_init(&req->lock, NULL);
	pthread_cond_init(&req->cond, NULL);
	req->state = REQ_PENDING;
	req->op = op;
	req->ok = 0;
	req->size = size;
	if (op == REQ_WRITE)
		bcopy(buffer, req->buf, size);

	switch (op) {
	case REQ_READ:
		op_atom = atom_read;
		break;
	case REQ_WRITE:
		op_atom = atom_write;
		break;
	default:
		op_atom = atom_flush;
		break;
	}
	msg_env = enif_alloc_env();
	msg = enif_make_tuple5(msg_env, atom_block, op_atom,
	    enif_make_uint64(msg_env, byte / ERX_LFS_SECTOR_SIZE),
	    enif_make_uint(msg_env, (unsigned)(size / ERX_LFS_SECTOR_SIZE)),
	    enif_make_resource(msg_env, req));
	sent = enif_send(vol->env, &vol->owner, msg_env, msg);
	enif_free_env(msg_env);

	ok = 0;
	if (sent) {
		deadline_after(&deadline, vol->deadline_ms);
		pthread_mutex_lock(&req->lock);
		while (req->state == REQ_PENDING) {
			rc = pthread_cond_timedwait(&req->cond, &req->lock,
			    &deadline);
			if (rc == ETIMEDOUT && req->state == REQ_PENDING)
				req->state = REQ_ENDED;
		}
		state = req->state;
		ok = state == REQ_DONE && req->ok;
		pthread_mutex_unlock(&req->lock);
		if (ok && op == REQ_READ)
			bcopy(req->buf, buffer, size);
	}
	enif_release_resource(req);
	if (!ok) {
		vol->broken = 1;
		return (LFS_ERR_IO);
	}
	return (0);
}

static int
bd_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
    void *buffer, lfs_size_t size)
{
	return (block_request(c, REQ_READ, block, off, buffer, size));
}

static int
bd_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
    const void *buffer, lfs_size_t size)
{
	return (block_request(c, REQ_WRITE, block, off, (void *)buffer,
	    size));
}

/* A block device erases nothing. */
static int
bd_erase(const struct lfs_config *c, lfs_block_t block)
{
	(void)c;
	(void)block;
	return (0);
}

static int
bd_sync(const struct lfs_config *c)
{
	return (block_request(c, REQ_FLUSH, 0, 0, NULL, 0));
}

/*
 * complete(Req, ok | {ok, Bytes} | error): the owner's answer to one block
 * request. A read's bytes must be exactly the request's size, or the answer
 * is an error. An answer after the deadline changes nothing and is `late`.
 */
static ERL_NIF_TERM
nif_complete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_lfs_req_t *req;
	ErlNifBinary bin;
	const ERL_NIF_TERM *tuple;
	int arity, ok, late;

	if (argc != 2 || !enif_get_resource(env, argv[0], req_type,
	    (void **)&req))
		return (enif_make_badarg(env));
	ok = 0;
	bin.data = NULL;
	bin.size = 0;
	if (enif_is_identical(argv[1], atom_ok))
		ok = req->op != REQ_READ;
	else if (enif_get_tuple(env, argv[1], &arity, &tuple) && arity == 2 &&
	    enif_is_identical(tuple[0], atom_ok) &&
	    enif_inspect_binary(env, tuple[1], &bin))
		ok = req->op == REQ_READ && bin.size == req->size;

	pthread_mutex_lock(&req->lock);
	late = req->state != REQ_PENDING;
	if (!late) {
		if (ok && req->op == REQ_READ)
			bcopy(bin.data, req->buf, req->size);
		req->ok = ok;
		req->state = REQ_DONE;
		pthread_cond_signal(&req->cond);
	}
	pthread_mutex_unlock(&req->lock);
	return (late ? atom_late : atom_ok);
}

/* payload(Req): a write's bytes, as a binary that keeps the request alive. */
static ERL_NIF_TERM
nif_payload(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_lfs_req_t *req;

	if (argc != 1 || !enif_get_resource(env, argv[0], req_type,
	    (void **)&req) || req->op != REQ_WRITE)
		return (enif_make_badarg(env));
	return (enif_make_resource_binary(env, req, req->buf, req->size));
}

/* ------------------------------------------------------------------------
 * The volume
 * ------------------------------------------------------------------------ */

/*
 * A volume's destructor frees only memory: every buffer littlefs uses is the
 * volume's own, so no littlefs call (which could do I/O) is needed.
 */
static void
vol_dtor(ErlNifEnv *env, void *obj)
{
	(void)env;
	(void)obj;
}

/* new(Owner, BlockCount, DeadlineMs): a volume over BlockCount blocks. */
static ERL_NIF_TERM
nif_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_lfs_vol_t *vol;
	ErlNifPid owner;
	unsigned blocks, deadline_ms;
	ERL_NIF_TERM term;

	if (argc != 3 || !enif_get_local_pid(env, argv[0], &owner) ||
	    !enif_get_uint(env, argv[1], &blocks) ||
	    !enif_get_uint(env, argv[2], &deadline_ms) ||
	    blocks < ERX_LFS_MIN_BLOCKS || blocks > ERX_LFS_MAX_BLOCKS ||
	    deadline_ms == 0 || deadline_ms > ERX_LFS_MAX_DEADLINE_MS)
		return (enif_make_badarg(env));
	vol = enif_alloc_resource(vol_type, sizeof(*vol));
	if (vol == NULL)
		return (error_posix(env, "enomem"));
	bzero(vol, sizeof(*vol));
	atomic_flag_clear(&vol->busy);
	vol->owner = owner;
	vol->deadline_ms = deadline_ms;
	erx_lfs_config(&vol->cfg, blocks);
	vol->cfg.context = vol;
	vol->cfg.read = bd_read;
	vol->cfg.prog = bd_prog;
	vol->cfg.erase = bd_erase;
	vol->cfg.sync = bd_sync;
	vol->cfg.read_buffer = vol->read_buf;
	vol->cfg.prog_buffer = vol->prog_buf;
	vol->cfg.lookahead_buffer = vol->lookahead_buf;
	term = enif_make_resource(env, vol);
	enif_release_resource(vol);
	return (term);
}

/*
 * Each operation enters through op_enter, which refuses a second caller and
 * records the environment block requests send from, and leaves through
 * op_leave.
 */
static int
op_enter(ErlNifEnv *env, const ERL_NIF_TERM vol_term, erx_lfs_vol_t **volp)
{
	erx_lfs_vol_t *vol;

	if (!enif_get_resource(env, vol_term, vol_type, (void **)&vol))
		return (0);
	if (atomic_flag_test_and_set(&vol->busy))
		return (-1);
	vol->env = env;
	*volp = vol;
	return (1);
}

static void
op_leave(erx_lfs_vol_t *vol)
{
	vol->env = NULL;
	atomic_flag_clear(&vol->busy);
}

/* A path from Erlang: no NUL inside, shorter than the buffer. */
static int
get_path(ErlNifEnv *env, ERL_NIF_TERM term, char *path, size_t len)
{
	ErlNifBinary bin;

	if (!enif_inspect_binary(env, term, &bin) || bin.size == 0 ||
	    bin.size >= len || memchr(bin.data, '\0', bin.size) != NULL)
		return (0);
	bcopy(bin.data, path, bin.size);
	path[bin.size] = '\0';
	return (1);
}

static erx_lfs_slot_t *
get_slot(ErlNifEnv *env, erx_lfs_vol_t *vol, ERL_NIF_TERM term)
{
	unsigned index;

	if (!enif_get_uint(env, term, &index) || index >= ERX_LFS_SLOTS ||
	    !vol->slots[index].used)
		return (NULL);
	return (&vol->slots[index]);
}

/* The operations, each run with the volume entered and mounted. */
enum vol_op {
	OP_FORMAT,
	OP_MOUNT,
	OP_STAT,
	OP_READDIR,
	OP_OPEN,
	OP_READ,
	OP_WRITE,
	OP_TRUNCATE,
	OP_SIZE,
	OP_SYNC,
	OP_CLOSE,
	OP_MKDIR,
	OP_REMOVE,
	OP_RENAME,
	OP_FSSTAT,
};

static ERL_NIF_TERM
op_format(ErlNifEnv *env, erx_lfs_vol_t *vol)
{
	int err;

	if (vol->mounted)
		return (error_posix(env, "ebusy"));
	err = lfs_format(&vol->lfs, &vol->cfg);
	return (err < 0 ? lfs_error(env, vol, err) : atom_ok);
}

static ERL_NIF_TERM
op_mount(ErlNifEnv *env, erx_lfs_vol_t *vol)
{
	int err;

	if (vol->mounted)
		return (error_posix(env, "ebusy"));
	err = lfs_mount(&vol->lfs, &vol->cfg);
	/* No volume found, distinct from a block failure: the owner formats. */
	if (err == LFS_ERR_CORRUPT && !vol->broken)
		return (error_posix(env, "eintegrity"));
	if (err < 0)
		return (lfs_error(env, vol, err));
	vol->mounted = 1;
	return (atom_ok);
}

static ERL_NIF_TERM
kind_atom(uint8_t type)
{
	return (type == LFS_TYPE_DIR ? atom_directory : atom_file);
}

/* stat(Vol, Path) -> {ok, file | directory, Size} */
static ERL_NIF_TERM
op_stat(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	char path[ERX_LFS_PATH_MAX];
	struct lfs_info info;
	int err;

	if (!get_path(env, argv[1], path, sizeof(path)))
		return (enif_make_badarg(env));
	err = lfs_stat(&vol->lfs, path, &info);
	if (err < 0)
		return (lfs_error(env, vol, err));
	return (enif_make_tuple3(env, atom_ok, kind_atom(info.type),
	    enif_make_uint(env, info.size)));
}

/*
 * readdir(Vol, Path, Skip, Max) -> {ok, [{Name, Kind, Size}]}: at most Max
 * entries after the first Skip, without "." and "..".
 */
static ERL_NIF_TERM
op_readdir(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	char path[ERX_LFS_PATH_MAX];
	struct lfs_info info;
	lfs_dir_t dir;
	ERL_NIF_TERM list, name, entry;
	unsigned skip, max, seen, taken;
	unsigned char *bytes;
	size_t len;
	int err;

	if (!get_path(env, argv[1], path, sizeof(path)) ||
	    !enif_get_uint(env, argv[2], &skip) ||
	    !enif_get_uint(env, argv[3], &max) || max == 0 ||
	    max > ERX_LFS_READDIR_MAX)
		return (enif_make_badarg(env));
	err = lfs_dir_open(&vol->lfs, &dir, path);
	if (err < 0)
		return (lfs_error(env, vol, err));
	list = enif_make_list(env, 0);
	seen = 0;
	taken = 0;
	while (taken < max && (err = lfs_dir_read(&vol->lfs, &dir, &info)) >
	    0) {
		if (strcmp(info.name, ".") == 0 || strcmp(info.name, "..") == 0)
			continue;
		if (seen++ < skip)
			continue;
		len = strnlen(info.name, sizeof(info.name));
		bytes = enif_make_new_binary(env, len, &name);
		bcopy(info.name, bytes, len);
		entry = enif_make_tuple3(env, name, kind_atom(info.type),
		    enif_make_uint(env, info.size));
		list = enif_make_list_cell(env, entry, list);
		taken++;
	}
	(void)lfs_dir_close(&vol->lfs, &dir);
	if (err < 0)
		return (lfs_error(env, vol, err));
	if (!enif_make_reverse_list(env, list, &list))
		return (error_posix(env, "eio"));
	return (enif_make_tuple2(env, atom_ok, list));
}

/* open(Vol, Path, Flags) -> {ok, Slot}, Flags littlefs's LFS_O_ bits. */
static ERL_NIF_TERM
op_open(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	char path[ERX_LFS_PATH_MAX];
	erx_lfs_slot_t *slot;
	unsigned flags, index;
	int err;

	if (!get_path(env, argv[1], path, sizeof(path)) ||
	    !enif_get_uint(env, argv[2], &flags) ||
	    (flags & ~(unsigned)(LFS_O_RDWR | LFS_O_CREAT | LFS_O_EXCL |
	    LFS_O_TRUNC | LFS_O_APPEND)) != 0 || (flags & LFS_O_RDWR) == 0)
		return (enif_make_badarg(env));
	for (index = 0; index < ERX_LFS_SLOTS; index++)
		if (!vol->slots[index].used)
			break;
	if (index == ERX_LFS_SLOTS)
		return (error_posix(env, "enfile"));
	slot = &vol->slots[index];
	bzero(&slot->cfg, sizeof(slot->cfg));
	slot->cfg.buffer = slot->cache;
	err = lfs_file_opencfg(&vol->lfs, &slot->file, path, (int)flags,
	    &slot->cfg);
	if (err < 0)
		return (lfs_error(env, vol, err));
	slot->used = 1;
	return (enif_make_tuple2(env, atom_ok, enif_make_uint(env, index)));
}

/*
 * littlefs asserts that a file is open for what is done to it, so a read of
 * a write-only file or a write of a read-only one is refused here first.
 */
static int
slot_allows(const erx_lfs_slot_t *slot, uint32_t access)
{
	return ((slot->file.flags & access) == access);
}

static int
get_offset(ErlNifEnv *env, ERL_NIF_TERM term, lfs_soff_t *off)
{
	ErlNifUInt64 value;

	if (!enif_get_uint64(env, term, &value) || value > LFS_FILE_MAX)
		return (0);
	*off = (lfs_soff_t)value;
	return (1);
}

/* read(Vol, Slot, Offset, Count) -> {ok, Bytes} */
static ERL_NIF_TERM
op_read(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	erx_lfs_slot_t *slot;
	ErlNifBinary bin;
	lfs_soff_t off;
	unsigned count;
	lfs_ssize_t got;
	ERL_NIF_TERM term;

	if ((slot = get_slot(env, vol, argv[1])) == NULL ||
	    !enif_get_uint(env, argv[3], &count) || count == 0 ||
	    count > ERX_LFS_IO_MAX)
		return (enif_make_badarg(env));
	if (!slot_allows(slot, LFS_O_RDONLY))
		return (error_posix(env, "ebadf"));
	if (!get_offset(env, argv[2], &off))
		return (error_posix(env, "efbig"));
	off = lfs_file_seek(&vol->lfs, &slot->file, off, LFS_SEEK_SET);
	if (off < 0)
		return (lfs_error(env, vol, off));
	if (!enif_alloc_binary(count, &bin))
		return (error_posix(env, "enomem"));
	got = lfs_file_read(&vol->lfs, &slot->file, bin.data, count);
	if (got < 0) {
		enif_release_binary(&bin);
		return (lfs_error(env, vol, got));
	}
	if (!enif_realloc_binary(&bin, (size_t)got)) {
		enif_release_binary(&bin);
		return (error_posix(env, "enomem"));
	}
	term = enif_make_binary(env, &bin);
	return (enif_make_tuple2(env, atom_ok, term));
}

/* write(Vol, Slot, Offset, Bytes) -> {ok, Count, At} */
static ERL_NIF_TERM
op_write(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	erx_lfs_slot_t *slot;
	ErlNifBinary bin;
	lfs_soff_t off;
	lfs_ssize_t put;
	lfs_soff_t end;

	if ((slot = get_slot(env, vol, argv[1])) == NULL ||
	    !enif_inspect_binary(env, argv[3], &bin) ||
	    bin.size > ERX_LFS_IO_MAX)
		return (enif_make_badarg(env));
	if (!slot_allows(slot, LFS_O_WRONLY))
		return (error_posix(env, "ebadf"));
	if (!get_offset(env, argv[2], &off) ||
	    bin.size > (size_t)(LFS_FILE_MAX - off))
		return (error_posix(env, "efbig"));
	off = lfs_file_seek(&vol->lfs, &slot->file, off, LFS_SEEK_SET);
	if (off < 0)
		return (lfs_error(env, vol, off));
	put = lfs_file_write(&vol->lfs, &slot->file, bin.data, bin.size);
	if (put < 0)
		return (lfs_error(env, vol, put));
	/* An append file writes at its end, so the offset is read back. */
	end = lfs_file_tell(&vol->lfs, &slot->file);
	if (end < put)
		return (lfs_error(env, vol, end < 0 ? end : LFS_ERR_IO));
	return (enif_make_tuple3(env, atom_ok, enif_make_uint(env,
	    (unsigned)put), enif_make_uint(env, (unsigned)(end - put))));
}

/* truncate(Vol, Slot, Size) -> ok */
static ERL_NIF_TERM
op_truncate(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	erx_lfs_slot_t *slot;
	lfs_soff_t size;
	int err;

	if ((slot = get_slot(env, vol, argv[1])) == NULL)
		return (enif_make_badarg(env));
	if (!slot_allows(slot, LFS_O_WRONLY))
		return (error_posix(env, "ebadf"));
	if (!get_offset(env, argv[2], &size))
		return (error_posix(env, "efbig"));
	err = lfs_file_truncate(&vol->lfs, &slot->file, (lfs_off_t)size);
	return (err < 0 ? lfs_error(env, vol, err) : atom_ok);
}

/* size(Vol, Slot) -> {ok, Size} */
static ERL_NIF_TERM
op_size(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	erx_lfs_slot_t *slot;
	lfs_soff_t size;

	if ((slot = get_slot(env, vol, argv[1])) == NULL)
		return (enif_make_badarg(env));
	size = lfs_file_size(&vol->lfs, &slot->file);
	if (size < 0)
		return (lfs_error(env, vol, size));
	return (enif_make_tuple2(env, atom_ok, enif_make_uint(env,
	    (unsigned)size)));
}

/* sync(Vol, Slot) -> ok: the file's data and metadata, then a flush. */
static ERL_NIF_TERM
op_sync(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	erx_lfs_slot_t *slot;
	int err;

	if ((slot = get_slot(env, vol, argv[1])) == NULL)
		return (enif_make_badarg(env));
	err = lfs_file_sync(&vol->lfs, &slot->file);
	if (err == 0)
		err = bd_sync(&vol->cfg);
	return (err < 0 ? lfs_error(env, vol, err) : atom_ok);
}

/*
 * close(Vol, Slot) -> ok: the slot is free afterwards even when littlefs's
 * close fails, since littlefs unlinks the file from its list either way.
 */
static ERL_NIF_TERM
op_close(ErlNifEnv *env, erx_lfs_vol_t *vol, const ERL_NIF_TERM argv[])
{
	erx_lfs_slot_t *slot;
	int err;

	if ((slot = get_slot(env, vol, argv[1])) == NULL)
		return (enif_make_badarg(env));
	err = lfs_file_close(&vol->lfs, &slot->file);
	slot->used = 0;
	return (err < 0 ? lfs_error(env, vol, err) : atom_ok);
}

static ERL_NIF_TERM
op_path(ErlNifEnv *env, erx_lfs_vol_t *vol, enum vol_op op,
    const ERL_NIF_TERM argv[])
{
	char path[ERX_LFS_PATH_MAX], to[ERX_LFS_PATH_MAX];
	int err;

	if (!get_path(env, argv[1], path, sizeof(path)) ||
	    (op == OP_RENAME && !get_path(env, argv[2], to, sizeof(to))))
		return (enif_make_badarg(env));
	switch (op) {
	case OP_MKDIR:
		err = lfs_mkdir(&vol->lfs, path);
		break;
	case OP_REMOVE:
		err = lfs_remove(&vol->lfs, path);
		break;
	default:
		err = lfs_rename(&vol->lfs, path, to);
		break;
	}
	return (err < 0 ? lfs_error(env, vol, err) : atom_ok);
}

/* fsstat(Vol) -> {ok, BlockSize, BlockCount, BlocksUsed} */
static ERL_NIF_TERM
op_fsstat(ErlNifEnv *env, erx_lfs_vol_t *vol)
{
	lfs_ssize_t used;

	used = lfs_fs_size(&vol->lfs);
	if (used < 0)
		return (lfs_error(env, vol, used));
	return (enif_make_tuple4(env, atom_ok,
	    enif_make_uint(env, vol->cfg.block_size),
	    enif_make_uint(env, vol->cfg.block_count),
	    enif_make_uint(env, (unsigned)used)));
}

static ERL_NIF_TERM
dispatch(ErlNifEnv *env, erx_lfs_vol_t *vol, enum vol_op op,
    const ERL_NIF_TERM argv[])
{
	if (op == OP_FORMAT)
		return (op_format(env, vol));
	if (op == OP_MOUNT)
		return (op_mount(env, vol));
	if (vol->broken)
		return (error_posix(env, "eio"));
	if (!vol->mounted)
		return (error_posix(env, "enodev"));
	switch (op) {
	case OP_STAT:
		return (op_stat(env, vol, argv));
	case OP_READDIR:
		return (op_readdir(env, vol, argv));
	case OP_OPEN:
		return (op_open(env, vol, argv));
	case OP_READ:
		return (op_read(env, vol, argv));
	case OP_WRITE:
		return (op_write(env, vol, argv));
	case OP_TRUNCATE:
		return (op_truncate(env, vol, argv));
	case OP_SIZE:
		return (op_size(env, vol, argv));
	case OP_SYNC:
		return (op_sync(env, vol, argv));
	case OP_CLOSE:
		return (op_close(env, vol, argv));
	case OP_MKDIR:
	case OP_REMOVE:
	case OP_RENAME:
		return (op_path(env, vol, op, argv));
	case OP_FSSTAT:
		return (op_fsstat(env, vol));
	default:
		return (enif_make_badarg(env));
	}
}

static ERL_NIF_TERM
run_op(ErlNifEnv *env, const ERL_NIF_TERM argv[], enum vol_op op)
{
	erx_lfs_vol_t *vol;
	ERL_NIF_TERM result;

	switch (op_enter(env, argv[0], &vol)) {
	case 0:
		return (enif_make_badarg(env));
	case -1:
		return (error_posix(env, "ebusy"));
	default:
		break;
	}
	if (vol->broken)
		result = error_posix(env, "eio");
	else
		result = dispatch(env, vol, op, argv);
	op_leave(vol);
	return (result);
}

/* One entry per operation; each runs on a dirty I/O scheduler. */
#define VOL_NIF(name, op)						\
	static ERL_NIF_TERM						\
	nif_##name(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])	\
	{								\
		(void)argc;						\
		return (run_op(env, argv, op));				\
	}

VOL_NIF(format, OP_FORMAT)
VOL_NIF(mount, OP_MOUNT)
VOL_NIF(stat, OP_STAT)
VOL_NIF(readdir, OP_READDIR)
VOL_NIF(open, OP_OPEN)
VOL_NIF(read, OP_READ)
VOL_NIF(write, OP_WRITE)
VOL_NIF(truncate, OP_TRUNCATE)
VOL_NIF(size, OP_SIZE)
VOL_NIF(sync, OP_SYNC)
VOL_NIF(close, OP_CLOSE)
VOL_NIF(mkdir, OP_MKDIR)
VOL_NIF(remove, OP_REMOVE)
VOL_NIF(rename, OP_RENAME)
VOL_NIF(fsstat, OP_FSSTAT)

#define DIRTY ERL_NIF_DIRTY_JOB_IO_BOUND

static ErlNifFunc nif_funcs[] = {
	{"new", 3, nif_new, 0},
	{"complete", 2, nif_complete, 0},
	{"payload", 1, nif_payload, 0},
	{"format", 1, nif_format, DIRTY},
	{"mount", 1, nif_mount, DIRTY},
	{"stat", 2, nif_stat, DIRTY},
	{"readdir", 4, nif_readdir, DIRTY},
	{"open", 3, nif_open, DIRTY},
	{"read", 4, nif_read, DIRTY},
	{"write", 4, nif_write, DIRTY},
	{"truncate", 3, nif_truncate, DIRTY},
	{"size", 2, nif_size, DIRTY},
	{"sync", 2, nif_sync, DIRTY},
	{"close", 2, nif_close, DIRTY},
	{"mkdir", 2, nif_mkdir, DIRTY},
	{"remove", 2, nif_remove, DIRTY},
	{"rename", 3, nif_rename, DIRTY},
	{"fsstat", 1, nif_fsstat, DIRTY},
};

static int
nif_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	(void)priv;
	(void)info;
	vol_type = enif_open_resource_type(env, NULL, "erx_lfs_vol", vol_dtor,
	    ERL_NIF_RT_CREATE, NULL);
	req_type = enif_open_resource_type(env, NULL, "erx_lfs_req", req_dtor,
	    ERL_NIF_RT_CREATE, NULL);
	if (vol_type == NULL || req_type == NULL)
		return (-1);
	atom_ok = mk_atom(env, "ok");
	atom_error = mk_atom(env, "error");
	atom_block = mk_atom(env, "erx_lfs_block");
	atom_read = mk_atom(env, "read");
	atom_write = mk_atom(env, "write");
	atom_flush = mk_atom(env, "flush");
	atom_file = mk_atom(env, "file");
	atom_directory = mk_atom(env, "directory");
	atom_late = mk_atom(env, "late");
	return (0);
}

ERL_NIF_INIT(erx_littlefs, nif_funcs, nif_load, NULL, NULL, NULL)
