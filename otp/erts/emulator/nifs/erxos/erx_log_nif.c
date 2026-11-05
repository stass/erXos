/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The calls under erx_log (docs/design-stopgap.md, "The console"): a labelled line into the
 * kernel log, and the console's read of the lines nobody has taken. A read checks each record
 * with the log core's own reader and writes it as a line through the core's renderer, so the
 * one escaping function of the log is the only one between a record and the console, and
 * no byte of a record's text reaches Erlang unescaped.
 *
 * Both are rare, a read a few times a second at most, so a NIF's call costs nothing that
 * counts.
 */

#define STATIC_ERLANG_NIF 1

#include <stdint.h>
#include <string.h>

#include "erl_nif.h"

#include "erx/abi.h"
#include "erx/log.h"
#include "liberx/backend/api.h"
#include "liberx/generated/calls.h"

/* Room for a few records of the longest text; a record is never split across reads. */
#define LOG_WINDOW_BYTES	(4 * ERX_LOG_RECORD_MAX)

/* One allocation for a read: the window, a record's checked text and its rendered line. */
typedef struct log_read_buffers {
	_Alignas(8) uint8_t	window[LOG_WINDOW_BYTES];
	char			text[ERX_LOG_TEXT_MAX];
	char			line[ERX_LOG_LINE_MAX];
} log_read_buffers_t;

static ERL_NIF_TERM
error_status(ErlNifEnv *env, int status)
{
	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_int(env, status)));
}

/*
 * debug_nif(Bytes): one erx_debug_log line of Bytes, at most ERX_UTCB_BYTES_MAX of them,
 * which the log escapes on the way in.
 */
static ERL_NIF_TERM
debug_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bytes;
	erx_utcb_t *const utcb = erx_utcb_self();
	int status;

	if (argc != 1 || !enif_inspect_iolist_as_binary(env, argv[0], &bytes) || bytes.size > ERX_UTCB_BYTES_MAX)
		return (enif_make_badarg(env));
	for (size_t done = 0; done < bytes.size; done += sizeof(uint64_t)) {
		const size_t part = bytes.size - done < sizeof(uint64_t) ? bytes.size - done : sizeof(uint64_t);
		uint64_t word = 0;

		memcpy(&word, bytes.data + done, part);
		(void)erx_utcb_mr_store(utcb, done / sizeof(uint64_t), word);
	}
	status = erx_debug_log((erx_utcb_length_t){ .raw = (uint32_t)bytes.size });
	if (status != ERX_OK)
		return (error_status(env, status));
	return (enif_make_atom(env, "ok"));
}

/*
 * read_nif(Cursor) -> {Whole, Next, Lost, Lines}: the lines of the records after Cursor,
 * oldest first, each ending in a newline; the cursor to pass next; and how many records were
 * overwritten before anyone read them. Whole is ok, or corrupt when a record of the window
 * failed the reader's checks, so the lines stop short of Next. A refused read is
 * {error, Status}.
 */
static ERL_NIF_TERM
read_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifUInt64 cursor;
	erx_log_read_result_t read;
	erx_log_view_t view;
	erx_log_next_t next = ERX_LOG_NEXT_END;
	log_read_buffers_t *buffers;
	ERL_NIF_TERM lines, line;
	size_t offset = 0, length;
	int status;

	if (argc != 1 || !enif_get_uint64(env, argv[0], &cursor))
		return (enif_make_badarg(env));
	buffers = enif_alloc(sizeof(*buffers));
	if (buffers == NULL)
		return (error_status(env, ERX_ENOMEM));
	status = erx_log_read(0, cursor, buffers->window, sizeof(buffers->window), &read);
	if (status != ERX_OK) {
		enif_free(buffers);
		return (error_status(env, status));
	}
	lines = enif_make_list(env, 0);
	if (read.written > sizeof(buffers->window))
		next = ERX_LOG_NEXT_CORRUPT;
	else
		while ((next = erx_log_next_record(buffers->window, (size_t)read.written, &offset, buffers->text,
		    &view)) == ERX_LOG_NEXT_RECORD) {
			length = erx_log_render(&view, buffers->line, sizeof(buffers->line));
			memcpy(enif_make_new_binary(env, length, &line), buffers->line, length);
			lines = enif_make_list_cell(env, line, lines);
		}
	enif_free(buffers);
	(void)enif_make_reverse_list(env, lines, &lines);
	return (enif_make_tuple4(env, enif_make_atom(env, next == ERX_LOG_NEXT_END ? "ok" : "corrupt"),
	    enif_make_uint64(env, read.next_cursor), enif_make_uint64(env, read.lost), lines));
}

static ErlNifFunc nif_funcs[] = {
	{ "debug_nif", 1, debug_nif, 0 },
	{ "read_nif", 1, read_nif, 0 },
};

ERL_NIF_INIT(erx_log, nif_funcs, NULL, NULL, NULL, NULL)
