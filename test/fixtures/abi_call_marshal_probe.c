/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the decoder and result store generated from abi_call_marshal.txt.
 * The expected message words are written out here by hand from the UTCB
 * byte rule (byte OFFSET is byte OFFSET % 8 of word OFFSET / 8, least
 * significant first), so the generator does not supply its own answers.
 */

#include <stdio.h>
#include <string.h>

#include "abi_calls.h"

/* A retrying call's handler alone takes the dispatch action. */
_Static_assert(_Generic(&erx_sys_ipc_send,
    erx_status_t (*)(erx_sys_context_t *, const erx_sys_ipc_send_args_t *,
    erx_sys_action_t *): 1, default: 0), "retry handler takes the action");
_Static_assert(_Generic(&erx_sys_park,
    erx_status_t (*)(erx_sys_context_t *, const erx_sys_park_args_t *): 1,
    default: 0), "other handlers cannot ask for a retry");

#define CHECK(condition)						\
	do {								\
		if (!(condition)) {					\
			printf("failed at line %d: %s\n", __LINE__,	\
			    #condition);				\
			return (1);					\
		}							\
	} while (0)

static void
fill(erx_utcb_t *utcb, uint64_t value)
{
	for (size_t index = 0; index < ERX_MSG_WORDS; index++)
		(void)erx_utcb_mr_store(utcb, index, value);
}

static uint64_t
word(const erx_utcb_t *utcb, size_t index)
{
	uint64_t value = 0;

	(void)erx_utcb_mr_load(utcb, index, &value);
	return (value);
}

/* The thread_write arguments: probe_regs at mr[2] and probe_grant at mr[6]. */
static void
write_arguments(erx_utcb_t *utcb)
{
	fill(utcb, UINT64_C(0xa5a5a5a5a5a5a5a5));
	(void)erx_utcb_mr_store(utcb, 2, UINT64_C(0x1122334455667788));
	(void)erx_utcb_mr_store(utcb, 3, UINT64_C(0x0000beef00000002));
	(void)erx_utcb_mr_store(utcb, 4, 7);
	(void)erx_utcb_mr_store(utcb, 5, 9);
	(void)erx_utcb_mr_store(utcb, 6, UINT64_C(0xfffffffb00636261));
}

static int
check_executor_rules(void)
{
	erx_sys_shape_t shape;
	uint64_t registers[6] = {0};

	CHECK(erx_sys_decode_shape(ERX_CALL_PARK, registers, NULL, true, &shape) == ERX_OK);
	CHECK(erx_sys_decode_shape(ERX_CALL_SPACE_STOP, registers, NULL, true, &shape) ==
	    ERX_EWOULDBLOCK);
	CHECK(erx_sys_decode_shape(ERX_CALL_SPACE_STOP, registers, NULL, false, &shape) == ERX_OK);
	/* The refusal answers before any argument is decoded. */
	registers[1] = UINT64_C(1) << 40;
	CHECK(erx_sys_decode_shape(ERX_CALL_SPACE_STOP, registers, NULL, true, &shape) ==
	    ERX_EWOULDBLOCK);
	CHECK(erx_sys_decode_shape(ERX_CALL_SPACE_STOP, registers, NULL, false, &shape) ==
	    ERX_EINVAL);
	registers[1] = 0;
	CHECK(erx_sys_decode_shape(ERX_CALL_IPC_SEND, registers, NULL, true, &shape) ==
	    ERX_EWOULDBLOCK);
	registers[0] = 8;
	CHECK(erx_sys_decode_shape(ERX_CALL_UMTX_WAIT, registers, NULL, true, &shape) == ERX_OK);
	CHECK(shape.arguments.umtx_wait.executor);
	CHECK(shape.arguments.umtx_wait.addr.raw == 8);
	CHECK(erx_sys_decode_shape(ERX_CALL_UMTX_WAIT, registers, NULL, false, &shape) == ERX_OK);
	CHECK(!shape.arguments.umtx_wait.executor);
	registers[0] = 6;
	CHECK(erx_sys_decode_shape(ERX_CALL_UMTX_WAIT, registers, NULL, true, &shape) == ERX_EINVAL);
	return (0);
}

static int
check_aggregate_arguments(void)
{
	erx_utcb_t utcb;
	erx_sys_shape_t shape;
	erx_sys_thread_write_args_t *write = &shape.arguments.thread_write;
	uint64_t registers[6] = {0};

	registers[0] = 3;
	write_arguments(&utcb);
	CHECK(erx_sys_decode_shape(ERX_CALL_THREAD_WRITE, registers, &utcb, false, &shape) == ERX_OK);
	CHECK(write->set == 3);
	CHECK(write->regs.pc == UINT64_C(0x1122334455667788));
	CHECK(write->regs.mode == ERX_PROBE_MODE_SLOW);
	CHECK(write->regs.flags == 0xbeef);
	CHECK(write->regs.gpr[0] == 7 && write->regs.gpr[1] == 9);
	CHECK(memcmp(write->grant.tag, "abc", 3) == 0);
	CHECK(write->grant.share == -5);

	/* Padding inside an aggregate, and the byte between two of its fields. */
	(void)erx_utcb_mr_store(&utcb, 3, UINT64_C(0x0001beef00000002));
	CHECK(erx_sys_decode_shape(ERX_CALL_THREAD_WRITE, registers, &utcb, false, &shape) ==
	    ERX_EINVAL);
	write_arguments(&utcb);
	(void)erx_utcb_mr_store(&utcb, 6, UINT64_C(0xfffffffb01636261));
	CHECK(erx_sys_decode_shape(ERX_CALL_THREAD_WRITE, registers, &utcb, false, &shape) ==
	    ERX_EINVAL);

	/* A field of an aggregate keeps its declared values. */
	write_arguments(&utcb);
	(void)erx_utcb_mr_store(&utcb, 3, UINT64_C(0x0000beef00000003));
	CHECK(erx_sys_decode_shape(ERX_CALL_THREAD_WRITE, registers, &utcb, false, &shape) ==
	    ERX_EINVAL);

	/* A register argument wider than its type, and a missing UTCB. */
	write_arguments(&utcb);
	registers[0] = UINT64_C(1) << 32;
	CHECK(erx_sys_decode_shape(ERX_CALL_THREAD_WRITE, registers, &utcb, false, &shape) ==
	    ERX_EINVAL);
	registers[0] = 3;
	CHECK(erx_sys_decode_shape(ERX_CALL_THREAD_WRITE, registers, NULL, false, &shape) ==
	    ERX_EINVAL);
	return (0);
}

static int
check_result_store(void)
{
	erx_utcb_t utcb;
	erx_sys_thread_read_results_t results = {0};
	uint64_t registers[2] = { UINT64_C(0xdead), UINT64_C(0xbeef) };

	fill(&utcb, UINT64_C(0x5a5a5a5a5a5a5a5a));
	results.count = 0x1234;
	results.regs.pc = UINT64_C(0x0102030405060708);
	results.regs.mode = ERX_PROBE_MODE_FAST;
	results.regs.flags = 0x7f;
	results.regs.gpr[0] = UINT64_MAX;
	results.regs.gpr[1] = 1;
	CHECK(erx_sys_thread_read_store(&results, registers, &utcb) == ERX_OK);
	CHECK(registers[0] == 0x1234);
	CHECK(registers[1] == 0);
	CHECK(word(&utcb, 58) == UINT64_C(0x5a5a5a5a5a5a5a5a));
	CHECK(word(&utcb, 59) == UINT64_C(0x0102030405060708));
	CHECK(word(&utcb, 60) == UINT64_C(0x0000007f00000001));
	CHECK(word(&utcb, 61) == UINT64_MAX);
	CHECK(word(&utcb, 62) == 1);
	CHECK(erx_sys_thread_read_store(&results, registers, NULL) == ERX_EINVAL);
	CHECK(erx_sys_thread_read_store(NULL, registers, &utcb) == ERX_EINVAL);
	return (0);
}

int
main(void)
{
	if (check_executor_rules() != 0 || check_aggregate_arguments() != 0 ||
	    check_result_store() != 0)
		return (1);
	puts("call marshalling checks passed");
	return (0);
}
