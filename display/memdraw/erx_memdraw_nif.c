/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The NIF of erx_memdraw (erlang/apps/erx_display/src/erx_memdraw.erl):
 * terms in, erx_memdraw.h's calls, terms out. An image is a resource
 * whose destructor alone frees it, so an image lives while any process
 * holds it (G2). A draw, load or read over 64 KiB of destination bytes
 * moves itself to a dirty CPU scheduler, so a full-screen compose never
 * holds a normal one, and a shape always runs on one. An image wrap/4
 * made over a connection's pixel area keeps the area's resource
 * (erx_area.h) until its destructor has freed it, so the area is never
 * unmapped under an image; one over the reader's read-only mapping is
 * refused as a destination, so no operation writes to it.
 */
#ifndef ERX_MEMDRAW_LOADABLE
#define STATIC_ERLANG_NIF 1
#endif
#include "erl_nif.h"

#include <stdbool.h>
#include <stdint.h>

#include "erx_area.h"
#include "erx_memdraw.h"

/* draw(3)'s colour meaning "do not fill". */
#define DNOFILL 0xFFFFFF00u
#define DIRTY_BYTES ((size_t)64 * 1024)

typedef struct image_res {
	erx_mdimage_t *image;
	void *area;		/* the kept area resource of a wrapped image, or NULL */
	bool readonly;		/* over a read-only area: never a destination */
} image_res_t;

static ErlNifResourceType *image_type;

#ifdef ERX_MEMDRAW_LOADABLE
/*
 * Loaded into stock's emulator, which has no erx_area, the bundle links
 * the test's stand-in area (test/display/erx_area_stand_in.c) instead.
 */
bool erx_area_stand_in_load(ErlNifEnv *env);
ERL_NIF_TERM erx_area_stand_in_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
#endif
static ERL_NIF_TERM atom_ok, atom_error, atom_einval, atom_enomem, atom_none, atom_dst, atom_opaque, atom_true,
    atom_false, atom_fill;

static void
image_dtor(ErlNifEnv *env, void *object)
{
	image_res_t *res = object;

	(void)env;
	if (res->image != NULL)
		erx_memdraw_free(res->image);
	/* Only now may the area go: nothing refers to its pixels any more. */
	if (res->area != NULL)
		enif_release_resource(res->area);
}

static bool
get_i32(ErlNifEnv *env, ERL_NIF_TERM term, int32_t *out)
{
	ErlNifSInt64 v;

	if (!enif_get_int64(env, term, &v) || v < INT32_MIN || v > INT32_MAX)
		return false;
	*out = (int32_t)v;
	return true;
}

static bool
get_u32(ErlNifEnv *env, ERL_NIF_TERM term, uint32_t *out)
{
	ErlNifUInt64 v;

	if (!enif_get_uint64(env, term, &v) || v > UINT32_MAX)
		return false;
	*out = (uint32_t)v;
	return true;
}

static bool
get_rect(ErlNifEnv *env, ERL_NIF_TERM term, erx_rect_t *r)
{
	const ERL_NIF_TERM *e;
	int arity;

	return enif_get_tuple(env, term, &arity, &e) && arity == 4 && get_i32(env, e[0], &r->x0) &&
	    get_i32(env, e[1], &r->y0) && get_i32(env, e[2], &r->x1) && get_i32(env, e[3], &r->y1);
}

static bool
get_point(ErlNifEnv *env, ERL_NIF_TERM term, erx_point_t *p)
{
	const ERL_NIF_TERM *e;
	int arity;

	return enif_get_tuple(env, term, &arity, &e) && arity == 2 && get_i32(env, e[0], &p->x) &&
	    get_i32(env, e[1], &p->y);
}

static bool
get_bool(ERL_NIF_TERM term, bool *out)
{
	if (enif_is_identical(term, atom_true))
		*out = true;
	else if (enif_is_identical(term, atom_false))
		*out = false;
	else
		return false;
	return true;
}

static bool
get_image(ErlNifEnv *env, ERL_NIF_TERM term, erx_mdimage_t **out)
{
	image_res_t *res;

	if (!enif_get_resource(env, term, image_type, (void **)&res) || res->image == NULL)
		return false;
	*out = res->image;
	return true;
}

/* An image an operation writes: any but one over a read-only area. */
static bool
get_dst(ErlNifEnv *env, ERL_NIF_TERM term, erx_mdimage_t **out)
{
	image_res_t *res;

	if (!enif_get_resource(env, term, image_type, (void **)&res) || res->image == NULL || res->readonly)
		return false;
	*out = res->image;
	return true;
}

static ERL_NIF_TERM
make_rect(ErlNifEnv *env, erx_rect_t r)
{
	return enif_make_tuple4(env, enif_make_int(env, r.x0), enif_make_int(env, r.y0), enif_make_int(env, r.x1),
	    enif_make_int(env, r.y1));
}

static ERL_NIF_TERM
error(ErlNifEnv *env, erx_memdraw_status_t status)
{
	return enif_make_tuple2(env, atom_error, status == ERX_MEMDRAW_ENOMEM ? atom_enomem : atom_einval);
}

/* {ok, Touched} for an operation that wrote pixels or none, else the error. */
static ERL_NIF_TERM
touched(ErlNifEnv *env, erx_memdraw_status_t status, erx_rect_t r)
{
	switch (status) {
	case ERX_MEMDRAW_DONE:
		return enif_make_tuple2(env, atom_ok, make_rect(env, r));
	case ERX_MEMDRAW_NOTHING:
		return enif_make_tuple2(env, atom_ok, atom_none);
	case ERX_MEMDRAW_EINVAL:
	case ERX_MEMDRAW_ENOMEM:
		break;
	}
	return error(env, status);
}

/* True when the call moved itself to a dirty scheduler; *result is its answer. */
static bool
gone_dirty(ErlNifEnv *env, size_t bytes, const char *name,
    ERL_NIF_TERM (*fun)(ErlNifEnv *, int, const ERL_NIF_TERM[]), int argc, const ERL_NIF_TERM argv[],
    ERL_NIF_TERM *result)
{
	if (bytes <= DIRTY_BYTES || enif_thread_type() != ERL_NIF_THR_NORMAL_SCHEDULER)
		return false;
	*result = enif_schedule_nif(env, name, ERL_NIF_DIRTY_JOB_CPU_BOUND, fun, argc, argv);
	return true;
}

/* alloc(Chan, R, Clipr, Repl, Color) -> {ok, Image} | {error, einval | enomem} */
static ERL_NIF_TERM
alloc_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uint32_t chan, color;
	erx_rect_t r, clipr;
	bool repl;

	(void)argc;
	if (!get_u32(env, argv[0], &chan) || !get_rect(env, argv[1], &r) || !get_rect(env, argv[2], &clipr) ||
	    !get_bool(argv[3], &repl) || !get_u32(env, argv[4], &color))
		return enif_make_badarg(env);
	image_res_t *res = enif_alloc_resource(image_type, sizeof *res);
	if (res == NULL)
		return error(env, ERX_MEMDRAW_ENOMEM);
	res->image = NULL;
	res->area = NULL;
	res->readonly = false;
	erx_memdraw_status_t status = erx_memdraw_alloc(&res->image, chan, r, clipr, repl, color);
	ERL_NIF_TERM term = enif_make_resource(env, res);
	enif_release_resource(res);
	return status == ERX_MEMDRAW_DONE ? enif_make_tuple2(env, atom_ok, term) : error(env, status);
}

/*
 * wrap(Area, Offset, R, Chan) -> {ok, Image} | {error, einval | enomem}:
 * an image of channel Chan over R whose pixels are Area's bytes from
 * Offset, a multiple of the page size, so every word libmemdraw loads or
 * stores is aligned; einval for an Offset off a page boundary or past the
 * area, and for rows that pass the area's end (erx_memdraw_wrap).
 */
static ERL_NIF_TERM
wrap_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_area_view_t area;
	ErlNifUInt64 offset;
	erx_rect_t r;
	uint32_t chan;

	(void)argc;
	if (!erx_area_view(env, argv[0], &area) || !enif_get_uint64(env, argv[1], &offset) ||
	    !get_rect(env, argv[2], &r) || !get_u32(env, argv[3], &chan))
		return enif_make_badarg(env);
	if (offset % area.page != 0 || offset >= area.bytes)
		return error(env, ERX_MEMDRAW_EINVAL);
	image_res_t *res = enif_alloc_resource(image_type, sizeof *res);
	if (res == NULL)
		return error(env, ERX_MEMDRAW_ENOMEM);
	res->image = NULL;
	res->area = NULL;
	res->readonly = !area.writable;
	erx_memdraw_status_t status =
	    erx_memdraw_wrap(&res->image, chan, r, area.base + offset, area.bytes - (size_t)offset);
	if (status == ERX_MEMDRAW_DONE) {
		enif_keep_resource(area.resource);
		res->area = area.resource;
	}
	ERL_NIF_TERM term = enif_make_resource(env, res);
	enif_release_resource(res);
	return status == ERX_MEMDRAW_DONE ? enif_make_tuple2(env, atom_ok, term) : error(env, status);
}

/* clip(Image, Repl, Clipr) -> ok */
static ERL_NIF_TERM
clip_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *image;
	bool repl;
	erx_rect_t clipr;

	(void)argc;
	if (!get_image(env, argv[0], &image) || !get_bool(argv[1], &repl) || !get_rect(env, argv[2], &clipr))
		return enif_make_badarg(env);
	erx_memdraw_set_clip(image, repl, clipr);
	return atom_ok;
}

/* draw(Dst, R, Src, Sp, Mask | opaque, Mp, Op, dst | Clipr) -> {ok, rect() | none} | {error, enomem} */
static ERL_NIF_TERM
draw_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *dst, *src, *mask = NULL;
	erx_rect_t r, clipr, out;
	erx_point_t sp, mp;
	int op;
	const erx_rect_t *clip = NULL;
	ERL_NIF_TERM result;

	if (!get_dst(env, argv[0], &dst) || !get_rect(env, argv[1], &r) || !get_image(env, argv[2], &src) ||
	    !get_point(env, argv[3], &sp) || !get_point(env, argv[5], &mp) || !enif_get_int(env, argv[6], &op))
		return enif_make_badarg(env);
	if (!enif_is_identical(argv[4], atom_opaque) && !get_image(env, argv[4], &mask))
		return enif_make_badarg(env);
	if (!enif_is_identical(argv[7], atom_dst)) {
		if (!get_rect(env, argv[7], &clipr))
			return enif_make_badarg(env);
		clip = &clipr;
	}
	if (gone_dirty(env, erx_memdraw_draw_bytes(dst, r, src, sp, mask, mp, clip), "draw", draw_nif, argc, argv,
	    &result))
		return result;
	return touched(env, erx_memdraw_draw(dst, r, src, sp, mask, mp, op, clip, &out), out);
}

/* A list of at most 2^20 {X, Y} points into *pts, allocated with enif_alloc; false on a bad term. */
static bool
get_points(ErlNifEnv *env, ERL_NIF_TERM list, erx_point_t **pts, size_t *n)
{
	unsigned len;
	ERL_NIF_TERM head;

	if (!enif_get_list_length(env, list, &len) || len > (1u << 20))
		return false;
	*pts = enif_alloc((len > 0 ? len : 1) * sizeof **pts);
	if (*pts == NULL)
		return false;
	for (unsigned i = 0; i < len; i++) {
		if (!enif_get_list_cell(env, list, &head, &list) || !get_point(env, head, &(*pts)[i])) {
			enif_free(*pts);
			return false;
		}
	}
	*n = len;
	return true;
}

/* An ellipse's thickness, or fill: -1, which libmemdraw takes as a fill. */
static bool
get_thick(ErlNifEnv *env, ERL_NIF_TERM term, int32_t *out)
{
	if (enif_is_identical(term, atom_fill)) {
		*out = -1;
		return true;
	}
	return get_i32(env, term, out) && *out >= 0;
}

/*
 * As touched/3, but a shape that failed with ENOMEM may have drawn part of
 * itself: {error, enomem, Touched | none}, so the window still marks it.
 */
static ERL_NIF_TERM
shape_touched(ErlNifEnv *env, erx_memdraw_status_t status, erx_rect_t r)
{
	if (status != ERX_MEMDRAW_ENOMEM)
		return touched(env, status, r);
	ERL_NIF_TERM drawn = r.x0 < r.x1 && r.y0 < r.y1 ? make_rect(env, r) : atom_none;

	return enif_make_tuple3(env, atom_error, atom_enomem, drawn);
}

/*
 * The shapes run on a dirty scheduler (their table entries): what one
 * costs follows from its geometry, not from the pixels it writes.
 */

/* line(Dst, P0, P1, End0, End1, Thick, Src, Sp, Op) -> {ok, rect() | none} | {error, einval | enomem} */
static ERL_NIF_TERM
line_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *dst, *src;
	erx_point_t p0, p1, sp;
	uint32_t end0, end1;
	int32_t thick;
	int op;
	erx_rect_t out = { 0, 0, 0, 0 };

	(void)argc;
	if (!get_dst(env, argv[0], &dst) || !get_point(env, argv[1], &p0) || !get_point(env, argv[2], &p1) ||
	    !get_u32(env, argv[3], &end0) || !get_u32(env, argv[4], &end1) || !get_i32(env, argv[5], &thick) ||
	    !get_image(env, argv[6], &src) || !get_point(env, argv[7], &sp) || !enif_get_int(env, argv[8], &op))
		return enif_make_badarg(env);
	return shape_touched(env, erx_memdraw_line(dst, p0, p1, end0, end1, thick, src, sp, op, &out), out);
}

/* poly(Dst, Points, End0, End1, Thick, Src, Sp, Op) -> as line/9 */
static ERL_NIF_TERM
poly_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *dst, *src;
	erx_point_t *pts, sp;
	size_t n;
	uint32_t end0, end1;
	int32_t thick;
	int op;
	erx_rect_t out = { 0, 0, 0, 0 };

	(void)argc;
	if (!get_dst(env, argv[0], &dst) || !get_u32(env, argv[2], &end0) || !get_u32(env, argv[3], &end1) ||
	    !get_i32(env, argv[4], &thick) || !get_image(env, argv[5], &src) || !get_point(env, argv[6], &sp) ||
	    !enif_get_int(env, argv[7], &op) || !get_points(env, argv[1], &pts, &n))
		return enif_make_badarg(env);
	erx_memdraw_status_t status = erx_memdraw_poly(dst, pts, n, end0, end1, thick, src, sp, op, &out);
	enif_free(pts);
	return shape_touched(env, status, out);
}

/* fill_poly(Dst, Points, Wind, Src, Sp, Op) -> as line/9 */
static ERL_NIF_TERM
fill_poly_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *dst, *src;
	erx_point_t *pts, sp;
	size_t n;
	int32_t wind;
	int op;
	erx_rect_t out = { 0, 0, 0, 0 };

	(void)argc;
	if (!get_dst(env, argv[0], &dst) || !get_i32(env, argv[2], &wind) || !get_image(env, argv[3], &src) ||
	    !get_point(env, argv[4], &sp) || !enif_get_int(env, argv[5], &op) || !get_points(env, argv[1], &pts, &n))
		return enif_make_badarg(env);
	erx_memdraw_status_t status = erx_memdraw_fill_poly(dst, pts, n, wind, src, sp, op, &out);
	enif_free(pts);
	return shape_touched(env, status, out);
}

/* ellipse(Dst, C, A, B, Thick | fill, Src, Sp, Op) -> as line/9 */
static ERL_NIF_TERM
ellipse_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *dst, *src;
	erx_point_t c, sp;
	int32_t a, b, thick;
	int op;
	erx_rect_t out = { 0, 0, 0, 0 };

	(void)argc;
	if (!get_dst(env, argv[0], &dst) || !get_point(env, argv[1], &c) || !get_i32(env, argv[2], &a) ||
	    !get_i32(env, argv[3], &b) || !get_thick(env, argv[4], &thick) || !get_image(env, argv[5], &src) ||
	    !get_point(env, argv[6], &sp) || !enif_get_int(env, argv[7], &op))
		return enif_make_badarg(env);
	return shape_touched(env, erx_memdraw_ellipse(dst, c, a, b, thick, src, sp, op, &out), out);
}

/* arc(Dst, C, A, B, Thick | fill, Src, Sp, Alpha, Phi, Op) -> as line/9 */
static ERL_NIF_TERM
arc_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *dst, *src;
	erx_point_t c, sp;
	int32_t a, b, thick, alpha, phi;
	int op;
	erx_rect_t out = { 0, 0, 0, 0 };

	(void)argc;
	if (!get_dst(env, argv[0], &dst) || !get_point(env, argv[1], &c) || !get_i32(env, argv[2], &a) ||
	    !get_i32(env, argv[3], &b) || !get_thick(env, argv[4], &thick) || !get_image(env, argv[5], &src) ||
	    !get_point(env, argv[6], &sp) || !get_i32(env, argv[7], &alpha) || !get_i32(env, argv[8], &phi) ||
	    !enif_get_int(env, argv[9], &op))
		return enif_make_badarg(env);
	return shape_touched(env, erx_memdraw_arc(dst, c, a, b, thick, src, sp, alpha, phi, op, &out), out);
}

/* load(Image, R, Pixels) -> {ok, rect()} | {error, einval} */
static ERL_NIF_TERM
load_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *image;
	erx_rect_t r, out;
	ErlNifBinary pixels;
	ERL_NIF_TERM result;

	if (!get_dst(env, argv[0], &image) || !get_rect(env, argv[1], &r) ||
	    !enif_inspect_binary(env, argv[2], &pixels))
		return enif_make_badarg(env);
	if (gone_dirty(env, erx_memdraw_rect_bytes(image, r), "load", load_nif, argc, argv, &result))
		return result;
	return touched(env, erx_memdraw_load(image, r, pixels.data, pixels.size, &out), out);
}

/* read(Image, R) -> {ok, binary()} | {error, einval | enomem} */
static ERL_NIF_TERM
read_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_mdimage_t *image;
	erx_rect_t r;
	size_t n;
	ERL_NIF_TERM result;

	if (!get_image(env, argv[0], &image) || !get_rect(env, argv[1], &r))
		return enif_make_badarg(env);
	erx_memdraw_status_t status = erx_memdraw_unload_size(image, r, &n);
	if (status != ERX_MEMDRAW_DONE)
		return error(env, status);
	if (gone_dirty(env, n, "read", read_nif, argc, argv, &result))
		return result;
	unsigned char *out = enif_make_new_binary(env, n, &result);
	if (out == NULL)
		return error(env, ERX_MEMDRAW_ENOMEM);
	status = erx_memdraw_unload(image, r, out, n);
	return status == ERX_MEMDRAW_DONE ? enif_make_tuple2(env, atom_ok, result) : error(env, status);
}

#ifdef ERX_MEMDRAW_CLOAD
/*
 * Test tool only: cload(Chan, R, Data) -> {ok, Pixels, Consumed} |
 * {error, einval | enomem}, 9front's cloadmemimage into a new image of
 * R, whose rows it writes whole, so Pixels are the decoded bytes.
 */
static ERL_NIF_TERM
cload_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uint32_t chan;
	erx_rect_t r;
	ErlNifBinary data;
	erx_mdimage_t *image;
	size_t consumed, n;
	ERL_NIF_TERM pixels;

	(void)argc;
	if (!get_u32(env, argv[0], &chan) || !get_rect(env, argv[1], &r) || !enif_inspect_binary(env, argv[2], &data))
		return enif_make_badarg(env);
	erx_memdraw_status_t status = erx_memdraw_alloc(&image, chan, r, r, false, DNOFILL);
	if (status != ERX_MEMDRAW_DONE)
		return error(env, status);
	status = erx_memdraw_cload(image, r, data.data, data.size, &consumed);
	if (status == ERX_MEMDRAW_DONE)
		status = erx_memdraw_unload_size(image, r, &n);
	unsigned char *out = status == ERX_MEMDRAW_DONE ? enif_make_new_binary(env, n, &pixels) : NULL;
	if (status == ERX_MEMDRAW_DONE && out == NULL)
		status = ERX_MEMDRAW_ENOMEM;
	if (status == ERX_MEMDRAW_DONE)
		status = erx_memdraw_unload(image, r, out, n);
	erx_memdraw_free(image);
	if (status != ERX_MEMDRAW_DONE)
		return error(env, status);
	return enif_make_tuple3(env, atom_ok, pixels, enif_make_uint64(env, consumed));
}
#endif

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	(void)priv;
	(void)info;
	image_type = enif_open_resource_type(env, NULL, "erx_memdraw_image", image_dtor, ERL_NIF_RT_CREATE, NULL);
	if (image_type == NULL || !erx_memdraw_init())
		return 1;
#ifdef ERX_MEMDRAW_LOADABLE
	if (!erx_area_stand_in_load(env))
		return 1;
#endif
	atom_ok = enif_make_atom(env, "ok");
	atom_error = enif_make_atom(env, "error");
	atom_einval = enif_make_atom(env, "einval");
	atom_enomem = enif_make_atom(env, "enomem");
	atom_none = enif_make_atom(env, "none");
	atom_dst = enif_make_atom(env, "dst");
	atom_opaque = enif_make_atom(env, "opaque");
	atom_true = enif_make_atom(env, "true");
	atom_false = enif_make_atom(env, "false");
	atom_fill = enif_make_atom(env, "fill");
	return 0;
}

static ErlNifFunc functions[] = {
	{ "alloc", 5, alloc_nif, 0 },
	{ "wrap", 4, wrap_nif, 0 },
	{ "clip", 3, clip_nif, 0 },
	{ "draw", 8, draw_nif, 0 },
	{ "load", 3, load_nif, 0 },
	{ "read", 2, read_nif, 0 },
	{ "line", 9, line_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "poly", 8, poly_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "fill_poly", 6, fill_poly_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "ellipse", 8, ellipse_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "arc", 10, arc_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
#ifdef ERX_MEMDRAW_CLOAD
	{ "cload", 3, cload_nif, 0 },
#endif
#ifdef ERX_MEMDRAW_LOADABLE
	{ "test_area", 2, erx_area_stand_in_nif, 0 },
#endif
};

ERL_NIF_INIT(erx_memdraw, functions, load, NULL, NULL, NULL)
