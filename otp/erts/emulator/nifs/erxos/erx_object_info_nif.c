/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The calls under erx_object_info (docs/design-live.md, "Inspection records"): a kernel
 * object's report as its bytes, and the topic's partial mask of the system domain's own
 * liberx. The NIF takes nothing apart: erx_schema:decode_report/2, generated from the
 * ABI, reads the bytes in Erlang, and the collector erx_kernel_records turns the two
 * masks into statuses. Both are rare, so a NIF's call costs nothing that counts.
 */

#define STATIC_ERLANG_NIF 1

#include <stdint.h>
#include <string.h>

#include "erl_nif.h"

#include "erx/abi.h"
#include "liberx/backend/api.h"

/* Room for the longest report the ABI declares. */
#define REPORT_BYTES_MAX	512u

_Static_assert(ERX_INFO_CPU_SIZE <= REPORT_BYTES_MAX && ERX_INFO_MACHINE_SIZE <= REPORT_BYTES_MAX &&
    ERX_INFO_GROUP_SIZE <= REPORT_BYTES_MAX && ERX_INFO_BUDGET_SIZE <= REPORT_BYTES_MAX &&
    ERX_INFO_THREAD_SIZE <= REPORT_BYTES_MAX, "every report fits the window");

/*
 * info_nif(Object, Topic, Index, Size) -> {ok, Bytes} | {error, Status}: the first Size
 * bytes of the window erx_object_info wrote, Size at most REPORT_BYTES_MAX, or the
 * call's refusal as its status number.
 */
static ERL_NIF_TERM
info_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	_Alignas(8) uint8_t window[REPORT_BYTES_MAX];
	ErlNifUInt64 object, index;
	unsigned int topic, size;
	ERL_NIF_TERM bytes;
	int status;

	if (argc != 4 || !enif_get_uint64(env, argv[0], &object) || !enif_get_uint(env, argv[1], &topic) ||
	    !enif_get_uint64(env, argv[2], &index) || !enif_get_uint(env, argv[3], &size) || size > sizeof(window))
		return (enif_make_badarg(env));
	memset(window, 0, sizeof(window));
	status = erx_object_info(object, topic, index, window, size);
	if (status != ERX_OK)
		return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_int(env, status)));
	memcpy(enif_make_new_binary(env, size, &bytes), window, size);
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), bytes));
}

/* partial_nif(Topic) -> Mask: the reported bits liberx's backend counts only partly. */
static ERL_NIF_TERM
partial_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned int topic;

	if (argc != 1 || !enif_get_uint(env, argv[0], &topic))
		return (enif_make_badarg(env));
	return (enif_make_uint(env, erx_info_partial(topic)));
}

static ErlNifFunc nif_funcs[] = {
	{ "info_nif", 4, info_nif, 0 },
	{ "partial_nif", 1, partial_nif, 0 },
};

ERL_NIF_INIT(erx_object_info, nif_funcs, NULL, NULL, NULL, NULL)
