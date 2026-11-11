/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of liberx's erx_prog C check (test/host/prog_profile_test.rb).
 * Each line of the requests file is "FRAME SCRATCH HEX": FRAME start or
 * request, SCRATCH full or half of what erx_prog_scratch_bytes promises,
 * HEX the frame's bytes.  Each answer line is "WIRE VERDICT": WIRE is
 * "wire" when erx_etf_next reads the bytes as items to their end and
 * "nowire" otherwise (the differential test's Erlang side refuses those
 * as malformed); VERDICT is "refused REASON KIND OFFSET", or for an
 * accepted start frame "accepted HEX", the frame written again from the
 * struct and every accessor with erx_etf's writer, which the test decodes
 * and compares with the frame's own term.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <erx/etf.h>
#include <erx/prog_profile.h>

#define LINE_MAX_BYTES	(2 * 300000 + 64)
#define OUT_MAX		(1024 * 1024)

static void
put_atom(erx_etf_writer_t *w, const char *name)
{
	erx_etf_put_atom(w, name, strlen(name));
}

static void
put_u64(erx_etf_writer_t *w, uint64_t v)
{
	uint8_t magnitude[8];
	size_t n;

	if (v <= INT64_MAX) {
		erx_etf_put_integer(w, (int64_t)v);
		return;
	}
	for (n = 0; n < 8; n++)
		magnitude[n] = (uint8_t)(v >> (8 * n));
	erx_etf_put_big(w, false, magnitude, 8);
}

static void
put_text(erx_etf_writer_t *w, erx_profile_text_t t)
{
	erx_etf_put_binary(w, t.bytes, t.len);
}

static void
put_signals(erx_etf_writer_t *w, erx_prog_signals_iter_t it)
{
	int32_t number;
	unsigned i;

	erx_etf_put_list(w, it.left);
	while (erx_prog_signals_next(&it, &number)) {
		for (i = 0; i < erx_prog_profile.nsignals; i++) {
			if (erx_prog_profile.signals[i].number == number)
				break;
		}
		put_atom(w, i < erx_prog_profile.nsignals ?
		    erx_prog_profile.signals[i].name : "?");
	}
	erx_etf_put_nil(w);
}

static void
put_texts(erx_etf_writer_t *w, erx_profile_list_t it, bool env)
{
	erx_profile_text_t t;

	erx_etf_put_list(w, it.left);
	while (env ? erx_prog_env_next(&it, &t) : erx_prog_argv_next(&it, &t))
		put_text(w, t);
	erx_etf_put_nil(w);
}

static void
put_pipe_end(erx_etf_writer_t *w, const erx_prog_pipe_end_t *e)
{
	erx_etf_put_tuple(w, 2);
	put_u64(w, e->pipe_id);
	put_u64(w, e->end_id);
}

static void
put_readers(erx_etf_writer_t *w, erx_profile_list_t it, bool write)
{
	erx_prog_reader_t r;

	erx_etf_put_list(w, it.left);
	while (write ? erx_prog_write_readers_next(&it, &r) :
	    erx_prog_read_readers_next(&it, &r)) {
		erx_etf_put_tuple(w, 2);
		put_u64(w, r.rix);
		put_u64(w, r.cap);
	}
	erx_etf_put_nil(w);
}

static void
put_write_end(erx_etf_writer_t *w, const erx_prog_write_end_t *e)
{
	erx_etf_put_map(w, 5);
	put_atom(w, "wend");
	put_u64(w, e->wend);
	put_atom(w, "ring");
	put_u64(w, e->ring);
	put_atom(w, "rpage");
	put_u64(w, e->rpage);
	put_atom(w, "size");
	put_u64(w, e->size);
	put_atom(w, "readers");
	put_readers(w, e->readers, true);
}

static void
put_read_end(erx_etf_writer_t *w, const erx_prog_read_end_t *e)
{
	erx_prog_writers_iter_t it;
	erx_prog_writer_t wr;

	erx_etf_put_map(w, 5);
	put_atom(w, "rix");
	put_u64(w, e->rix);
	put_atom(w, "lock");
	put_u64(w, e->lock);
	put_atom(w, "wends");
	put_u64(w, e->wends);
	put_atom(w, "writers");
	it = e->writers;
	erx_etf_put_list(w, it.left);
	while (erx_prog_writers_next(&it, &wr)) {
		erx_etf_put_tuple(w, 6);
		put_u64(w, wr.wend);
		put_u64(w, wr.cap_1);
		put_u64(w, wr.cap_2);
		put_u64(w, wr.lane_size);
		put_u64(w, wr.cap_3);
		put_atom(w, wr.writer_state == ERX_PROG_WRITER_STATE_OPEN ?
		    "open" : "gone");
	}
	erx_etf_put_nil(w);
	put_atom(w, "readers");
	put_readers(w, e->readers, false);
}

static const char *
access_name(uint16_t access)
{
	switch (access) {
	case ERX_PROG_ACCESS_READ:
		return ("read");
	case ERX_PROG_ACCESS_WRITE:
		return ("write");
	default:
		return ("read_write");
	}
}

static void
put_descriptor(erx_etf_writer_t *w, const erx_prog_descriptor_t *d)
{
	switch (d->which) {
	case ERX_PROG_DESCRIPTOR_PIPE_WRITE:
		erx_etf_put_tuple(w, 4);
		put_atom(w, "pipe");
		put_atom(w, "write");
		put_pipe_end(w, &d->u.pipe_write.pipe_end);
		put_write_end(w, &d->u.pipe_write.write_end);
		break;
	case ERX_PROG_DESCRIPTOR_PIPE_READ:
		erx_etf_put_tuple(w, 4);
		put_atom(w, "pipe");
		put_atom(w, "read");
		put_pipe_end(w, &d->u.pipe_read.pipe_end);
		put_read_end(w, &d->u.pipe_read.read_end);
		break;
	case ERX_PROG_DESCRIPTOR_SOCKETPAIR:
		erx_etf_put_tuple(w, 5);
		put_atom(w, "socketpair");
		put_pipe_end(w, &d->u.socketpair.pipe_end_1);
		put_read_end(w, &d->u.socketpair.read_end);
		put_pipe_end(w, &d->u.socketpair.pipe_end_2);
		put_write_end(w, &d->u.socketpair.write_end);
		break;
	case ERX_PROG_DESCRIPTOR_FILE:
	case ERX_PROG_DESCRIPTOR_TTY:
		erx_etf_put_tuple(w, 3);
		put_atom(w, d->which == ERX_PROG_DESCRIPTOR_FILE ? "file" : "tty");
		put_u64(w, d->which == ERX_PROG_DESCRIPTOR_FILE ?
		    d->u.file.open : d->u.tty.open);
		put_atom(w, access_name(d->which == ERX_PROG_DESCRIPTOR_FILE ?
		    d->u.file.access : d->u.tty.access));
		break;
	case ERX_PROG_DESCRIPTOR_DIR:
	case ERX_PROG_DESCRIPTOR_SOCKET:
		erx_etf_put_tuple(w, 2);
		put_atom(w, d->which == ERX_PROG_DESCRIPTOR_DIR ? "dir" : "socket");
		put_u64(w, d->which == ERX_PROG_DESCRIPTOR_DIR ?
		    d->u.dir.open : d->u.socket.open);
		break;
	case ERX_PROG_DESCRIPTOR_DUP:
		erx_etf_put_tuple(w, 2);
		put_atom(w, "dup");
		put_u64(w, d->u.dup.dup_target);
		break;
	default:
		put_atom(w, "null");
		break;
	}
}

/* The start frame again, from the struct and its iterators. */
static bool
put_start(const erx_prog_start_t *s, uint8_t *out, size_t cap, size_t *len)
{
	erx_prog_fds_iter_t fds;
	erx_prog_fd_entry_t entry;
	erx_etf_writer_t w;

	erx_etf_writer_init(&w, out, cap);
	erx_etf_put_tuple(&w, 3);
	put_atom(&w, "erx_start");
	put_u64(&w, 1);
	erx_etf_put_map(&w, s->has_image ? 13 : 12);
	put_atom(&w, "pid");
	put_u64(&w, s->pid);
	put_atom(&w, "ppid");
	put_u64(&w, s->ppid);
	put_atom(&w, "pgid");
	put_u64(&w, s->pgid);
	put_atom(&w, "argv");
	put_texts(&w, s->argv, false);
	put_atom(&w, "env");
	put_texts(&w, s->env, true);
	put_atom(&w, "cwd");
	put_text(&w, s->cwd);
	put_atom(&w, "spawn");
	put_atom(&w, s->spawn ? "true" : "false");
	put_atom(&w, "sigmask");
	put_signals(&w, s->sigmask);
	put_atom(&w, "sigignore");
	put_signals(&w, s->sigignore);
	put_atom(&w, "umask");
	put_u64(&w, s->umask);
	put_atom(&w, "data_area");
	erx_etf_put_tuple(&w, 2);
	put_u64(&w, s->data_area.cap);
	put_u64(&w, s->data_area.data_slots);
	put_atom(&w, "fds");
	fds = s->fds;
	erx_etf_put_list(&w, fds.left);
	while (erx_prog_fds_next(&fds, &entry)) {
		erx_etf_put_tuple(&w, 2);
		put_u64(&w, entry.fd);
		put_descriptor(&w, &entry.descriptor);
	}
	erx_etf_put_nil(&w);
	if (s->has_image) {
		put_atom(&w, "image");
		erx_etf_put_tuple(&w, 2);
		put_atom(&w, "object");
		put_u64(&w, s->image.u.object.cap);
	}
	return (erx_etf_writer_done(&w, len));
}

static bool
wire(const uint8_t *b, size_t len)
{
	erx_etf_reader_t r;
	erx_etf_item_t item;
	erx_etf_reason_t reason;
	erx_etf_step_t step;

	if (!erx_etf_reader_init(&r, b, len))
		return (false);
	while ((step = erx_etf_next(&r, &item, &reason)) == ERX_ETF_STEP_ITEM)
		;
	return (step == ERX_ETF_STEP_END);
}

static size_t
unhex(const char *hex, uint8_t *out, size_t cap)
{
	size_t i, n;
	unsigned v;

	n = strlen(hex) / 2;
	if (n > cap)
		return (SIZE_MAX);
	for (i = 0; i < n; i++) {
		if (sscanf(hex + 2 * i, "%2x", &v) != 1)
			return (SIZE_MAX);
		out[i] = (uint8_t)v;
	}
	return (n);
}

int
main(int argc, char **argv)
{
	static char line[LINE_MAX_BYTES];
	static uint8_t frame[LINE_MAX_BYTES / 2], out[OUT_MAX];
	char kind[16], scratch_mode[8], *hex;
	erx_profile_refusal_t refusal;
	uint16_t request;
	erx_prog_start_t start;
	FILE *in, *answers;
	size_t len, need, have, out_len, i;
	uint8_t *scratch, slot;
	bool ok;

	if (argc != 3 || (in = fopen(argv[1], "r")) == NULL ||
	    (answers = fopen(argv[2], "w")) == NULL)
		return (2);
	while (fgets(line, sizeof(line), in) != NULL) {
		line[strcspn(line, "\n")] = '\0';
		hex = strrchr(line, ' ');
		if (hex == NULL || sscanf(line, "%15s %7s", kind, scratch_mode) != 2)
			return (2);
		len = unhex(hex + 1, frame, sizeof(frame));
		if (len == SIZE_MAX)
			return (2);
		need = erx_prog_scratch_bytes(len);
		have = strcmp(scratch_mode, "half") == 0 ? need / 2 : need;
		/*
		 * Exactly have bytes at an odd address, so ASan sees a write
		 * past them and the check must align its arrays itself.
		 */
		scratch = malloc(have + 3);
		if (scratch == NULL)
			return (2);
		if (strcmp(kind, "start") == 0)
			ok = erx_prog_check_start(frame, len, scratch + 3, have, &start,
			    &refusal);
		else
			ok = erx_prog_check_request(frame, len, scratch + 3, have,
			    &slot, &request, &refusal);
		free(scratch);
		fprintf(answers, "%s ", wire(frame, len) ? "wire" : "nowire");
		if (!ok) {
			fprintf(answers, "refused %s %s %zu\n",
			    erx_profile_reason_name(refusal.reason),
			    erx_prog_kind_name(refusal.kind), refusal.offset);
			continue;
		}
		if (strcmp(kind, "start") != 0 ||
		    !put_start(&start, out, sizeof(out), &out_len)) {
			fprintf(answers, "accepted -\n");
			continue;
		}
		fprintf(answers, "accepted ");
		for (i = 0; i < out_len; i++)
			fprintf(answers, "%02x", out[i]);
		fprintf(answers, "\n");
	}
	fclose(in);
	return (fclose(answers) == 0 ? 0 : 1);
}
