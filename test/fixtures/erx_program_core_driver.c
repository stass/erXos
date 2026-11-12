/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host driver of the erx_program port's core (otp/erts/emulator/sys/erxos/erx_program_core.c),
 * for test/host/erx_program_core_test.rb, which holds every expectation. It prints, one line
 * each and numbers only, enums by their value:
 *
 *   spec NAME STATUS                   erx_program_spec_check's answer for a named spec
 *   act VALUE NAME, phase VALUE NAME   the enums' names
 *   install INDEX NAME RIGHTS          what the program's table receives at each index
 *   batch FIRST COUNT                  erx_program_install_batch's answer from each index, and past them
 *   start NAME ACT... = ERROR          a start's whole run, each action it returned in order
 *   end STATE INPUT... = STATE ACT:STATUS...
 *                                      one input in one state of the end, every state reachable
 *                                      from a started program by every input of the alphabet
 *
 * A start named fail-K fails the K-th action it returns with STEP_FAILURE and every other
 * with ERX_OK; undo-fail-K also fails every action after the K-th, whose outcomes the core
 * must not read. A STATE is the end's phase, its status, and whether the anchor ended, the
 * answer was read and the close is held, as 0 or 1. An input is "image_exit STATUS" or
 * "anchor_exit STATUS" (an exit record of that space made into an input by
 * erx_program_input_of), "fault KIND" (a record of that kind from the image), "close",
 * "lost" or "answered". A run that never ends, or an end that writes past its bound, is a
 * broken core: the driver says so and exits 2.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_program_core.h"

#define STEP_FAILURE	ERX_ELIMIT
#define UNDO_FAILURE	ERX_EINVAL
/* More actions than any start can return: steps and undos, each at most once. */
#define RUN_BOUND	64
#define STATES_MAX	256

static const char good_image[] = "bin/exit42";
/* Every fault kind, and kinds no record names. */
static const uint32_t kinds[] = { 0, ERX_FAULT_MEMORY, ERX_FAULT_DELETED, ERX_FAULT_UNDEFINED,
    ERX_FAULT_ALIGNMENT, ERX_FAULT_BREAKPOINT, ERX_FAULT_FOREIGN_TRAP, ERX_FAULT_ASYNC_ERROR,
    ERX_FAULT_BUDGET, 10, UINT32_MAX };

static erx_program_spec_t
spec_of(const char *image, size_t len, int64_t pid, uint64_t guarantee, uint64_t cap)
{
	return ((erx_program_spec_t){ .image = (const uint8_t *)image, .image_len = len, .pid = pid,
	    .guarantee = guarantee, .cap = cap });
}

static erx_program_spec_t
spec_named_image(const char *image)
{
	return (spec_of(image, strlen(image), 2, 1, 2));
}

#define POOL	UINT64_C(1000)

static void
print_spec(const char *name, erx_program_spec_t spec)
{
	printf("spec %s %d\n", name, erx_program_spec_check(&spec, POOL));
}

static void
specs(void)
{
	static char longest[ERX_PACK_PATH_MAX + 1];

	memset(longest, 'a', sizeof(longest));
	print_spec("good", spec_named_image(good_image));
	print_spec("one-byte", spec_named_image("a"));
	print_spec("empty", spec_of(good_image, 0, 2, 1, 2));
	print_spec("absolute", spec_named_image("/bin/exit42"));
	print_spec("trailing-slash", spec_named_image("bin/"));
	print_spec("empty-component", spec_named_image("bin//exit42"));
	print_spec("dot", spec_named_image("bin/./exit42"));
	print_spec("dot-dot", spec_named_image("bin/../exit42"));
	print_spec("dot-alone", spec_named_image("."));
	print_spec("dot-dot-alone", spec_named_image(".."));
	print_spec("dot-prefix", spec_named_image("bin/.hidden"));
	print_spec("dots-name", spec_named_image("bin/..."));
	print_spec("control", spec_named_image("bin/ex\001t"));
	print_spec("delete", spec_named_image("bin/ex\177t"));
	print_spec("nul", spec_of("bin\0x", 5, 2, 1, 2));
	print_spec("high-byte", spec_named_image("bin/\303\251"));
	print_spec("longest", spec_of(longest, ERX_PACK_PATH_MAX, 2, 1, 2));
	print_spec("too-long", spec_of(longest, ERX_PACK_PATH_MAX + 1, 2, 1, 2));
	print_spec("pid-0", spec_of(good_image, strlen(good_image), 0, 1, 2));
	print_spec("pid-1", spec_of(good_image, strlen(good_image), 1, 1, 2));
	print_spec("pid-negative", spec_of(good_image, strlen(good_image), -2, 1, 2));
	print_spec("pid-max", spec_of(good_image, strlen(good_image), INT64_C(0x7fffffff), 1, 2));
	print_spec("pid-past-max", spec_of(good_image, strlen(good_image), INT64_C(0x80000000), 1, 2));
	print_spec("pid-int64-min", spec_of(good_image, strlen(good_image), INT64_MIN, 1, 2));
	print_spec("guarantee-equals-cap", spec_of(good_image, strlen(good_image), 2, 7, 7));
	print_spec("guarantee-above-cap", spec_of(good_image, strlen(good_image), 2, 8, 7));
	print_spec("cap-equals-pool", spec_of(good_image, strlen(good_image), 2, 0, POOL));
	print_spec("cap-above-pool", spec_of(good_image, strlen(good_image), 2, 0, POOL + 1));
	print_spec("cap-max", spec_of(good_image, strlen(good_image), 2, 0, UINT64_MAX));
}

/* One start's run, failing the fail_at-th action (0 for none), and every later one when undo_fails. */
static void
start_run(const char *name, erx_program_spec_t spec, unsigned fail_at, int undo_fails)
{
	erx_program_start_t run;
	int result = ERX_OK;

	erx_program_start_begin(&run, &spec, POOL);
	printf("start %s", name);
	for (unsigned count = 1; count <= RUN_BOUND; count++) {
		const erx_program_act_t act = erx_program_start_next(&run, result);

		if (act == ERX_PROGRAM_DONE) {
			printf(" = %d\n", run.error);
			return;
		}
		printf(" %d", (int)act);
		result = count == fail_at ? STEP_FAILURE : (fail_at != 0 && count > fail_at && undo_fails) ?
		    UNDO_FAILURE : ERX_OK;
	}
	printf("\nbroken start %s: no end after %d actions\n", name, RUN_BOUND);
	exit(2);
}

/*
 * Misuse the driver must not be able to turn into harm: a failure fed on the first call
 * has nothing to undo, and a result fed after DONE changes nothing.
 */
static void
start_misuse(void)
{
	const erx_program_spec_t good = spec_named_image(good_image);
	erx_program_start_t run;
	erx_program_act_t act;

	erx_program_start_begin(&run, &good, POOL);
	printf("start first-call-fails");
	for (int result = STEP_FAILURE; (act = erx_program_start_next(&run, result)) != ERX_PROGRAM_DONE;
	    result = ERX_OK)
		printf(" %d", (int)act);
	printf(" = %d\n", run.error);

	erx_program_start_begin(&run, &good, POOL);
	printf("start after-done");
	while ((act = erx_program_start_next(&run, ERX_OK)) != ERX_PROGRAM_DONE)
		printf(" %d", (int)act);
	for (int again = 0; again < 2; again++) {
		if ((act = erx_program_start_next(&run, STEP_FAILURE)) != ERX_PROGRAM_DONE)
			printf(" %d", (int)act);
	}
	printf(" = %d\n", run.error);
}

static void
starts(void)
{
	const erx_program_spec_t good = spec_named_image(good_image);
	char name[32];

	start_run("ok", good, 0, 0);
	start_misuse();
	start_run("refused", spec_of(good_image, strlen(good_image), 1, 1, 2), 0, 0);
	/* Past the last step a failure is never asked for, so its run is the one that succeeded. */
	for (unsigned k = 1; k <= ERX_PROGRAM_THREAD_START; k++) {
		snprintf(name, sizeof(name), "fail-%u", k);
		start_run(name, good, k, 0);
		snprintf(name, sizeof(name), "undo-fail-%u", k);
		start_run(name, good, k, 1);
	}
}

/*
 * The end's input alphabet: every record kind, exit statuses of every class from the image,
 * the anchor's exits, a close, a loss and the answer.
 */
typedef struct {
	char			text[48];
	erx_program_input_t	input;
} input_t;

static size_t
alphabet(input_t inputs[], size_t max)
{
	static const int64_t anchor_statuses[] = { ERX_PROGRAM_KILLED, ERX_EXIT_PARENT };
	static const int64_t statuses[] = { 0, 42, 255, 256, ERX_EXIT_SIGNAL + ERX_SIGKILL,
	    ERX_EXIT_SIGNAL + ERX_SIGSEGV, ERX_EXIT_PARENT, ERX_EXIT_NOTHREAD, ERX_EXIT_RELEASED, ERX_EXIT_CRASH,
	    -1, INT64_MAX };
	size_t n = 0;

	for (size_t i = 0; i < sizeof(statuses) / sizeof(statuses[0]) && n < max; i++, n++) {
		const erx_fault_t record = { .kind = ERX_FAULT_EXIT, .status = statuses[i] };

		snprintf(inputs[n].text, sizeof(inputs[n].text), "image_exit %" PRId64, statuses[i]);
		inputs[n].input = erx_program_input_of(&record, ERX_PROGRAM_SPACE_IMAGE);
	}
	for (size_t i = 0; i < sizeof(anchor_statuses) / sizeof(anchor_statuses[0]) && n < max; i++, n++) {
		const erx_fault_t record = { .kind = ERX_FAULT_EXIT, .status = anchor_statuses[i] };

		snprintf(inputs[n].text, sizeof(inputs[n].text), "anchor_exit %" PRId64, anchor_statuses[i]);
		inputs[n].input = erx_program_input_of(&record, ERX_PROGRAM_SPACE_ANCHOR);
	}
	for (size_t i = 0; i < sizeof(kinds) / sizeof(kinds[0]) && n < max; i++, n++) {
		/* A fault record's status is not the program's: a stray one must change nothing. */
		const erx_fault_t record = { .kind = (erx_fault_kind_t)kinds[i], .status = 77 };

		snprintf(inputs[n].text, sizeof(inputs[n].text), "fault %" PRIu32, kinds[i]);
		inputs[n].input = erx_program_input_of(&record, ERX_PROGRAM_SPACE_IMAGE);
	}
	if (n + 3 <= max) {
		snprintf(inputs[n].text, sizeof(inputs[n].text), "close");
		inputs[n++].input = (erx_program_input_t){ .kind = ERX_PROGRAM_CLOSE };
		snprintf(inputs[n].text, sizeof(inputs[n].text), "lost");
		inputs[n++].input = (erx_program_input_t){ .kind = ERX_PROGRAM_LOST };
		snprintf(inputs[n].text, sizeof(inputs[n].text), "answered");
		inputs[n++].input = (erx_program_input_t){ .kind = ERX_PROGRAM_ANSWERED };
	}
	return (n);
}

static int
same_state(erx_program_end_t a, erx_program_end_t b)
{
	return (a.phase == b.phase && a.status == b.status && a.anchor_ended == b.anchor_ended &&
	    a.answered == b.answered && a.close_held == b.close_held);
}

static void
print_state(erx_program_end_t end)
{
	printf(" %d %" PRId64 " %d %d %d", (int)end.phase, end.status, end.anchor_ended, end.answered,
	    end.close_held);
}

/* Every state reachable from a started program, and every input in each. */
static void
ends(void)
{
	input_t inputs[48];
	const size_t count = alphabet(inputs, sizeof(inputs) / sizeof(inputs[0]));
	erx_program_end_t states[STATES_MAX];
	size_t known = 1;

	states[0] = erx_program_end_begin();
	for (size_t at = 0; at < known; at++) {
		for (size_t i = 0; i < count; i++) {
			erx_program_end_t end = states[at];
			erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX + 1];
			size_t written, seen;

			memset(actions, 0, sizeof(actions));
			written = erx_program_end_next(&end, inputs[i].input, actions);
			if (written > ERX_PROGRAM_ACTIONS_MAX) {
				printf("broken end: %zu actions\n", written);
				exit(2);
			}
			printf("end");
			print_state(states[at]);
			printf(" %s =", inputs[i].text);
			print_state(end);
			for (size_t a = 0; a < written; a++)
				printf(" %d:%" PRId64, (int)actions[a].act, actions[a].status);
			printf("\n");
			for (seen = 0; seen < known && !same_state(states[seen], end); seen++)
				continue;
			if (seen == known) {
				if (known == STATES_MAX) {
					printf("broken end: more than %d states\n", STATES_MAX);
					exit(2);
				}
				states[known++] = end;
			}
		}
	}
}

/* Each enum value's name, by its designator, so the test copies no numbering. */
static const char *const act_names[] = {
	[ERX_PROGRAM_DONE] = "done",
	[ERX_PROGRAM_CHANNEL_CREATE] = "channel_create",
	[ERX_PROGRAM_CHANNEL_MAP] = "channel_map",
	[ERX_PROGRAM_BELL_CREATE] = "bell_create",
	[ERX_PROGRAM_DATA_CREATE] = "data_create",
	[ERX_PROGRAM_IRQ_CREATE] = "irq_create",
	[ERX_PROGRAM_SINK_REGISTER] = "sink_register",
	[ERX_PROGRAM_IRQ_BIND] = "irq_bind",
	[ERX_PROGRAM_BUDGET_CREATE] = "budget_create",
	[ERX_PROGRAM_GROUP_CREATE] = "group_create",
	[ERX_PROGRAM_GATE_REGISTER_ANCHOR] = "gate_register_anchor",
	[ERX_PROGRAM_GATE_REGISTER_IMAGE] = "gate_register_image",
	[ERX_PROGRAM_ANCHOR_CREATE] = "anchor_create",
	[ERX_PROGRAM_IMAGE_CREATE] = "image_create",
	[ERX_PROGRAM_IMAGE_MAP] = "image_map",
	[ERX_PROGRAM_INSTALL] = "install",
	[ERX_PROGRAM_BELL_BIND] = "bell_bind",
	[ERX_PROGRAM_THREAD_CREATE] = "thread_create",
	[ERX_PROGRAM_THREAD_START] = "thread_start",
	[ERX_PROGRAM_THREAD_CLOSE] = "thread_close",
	[ERX_PROGRAM_BELL_UNBIND] = "bell_unbind",
	[ERX_PROGRAM_IMAGE_CLOSE] = "image_close",
	[ERX_PROGRAM_ANCHOR_DESTROY] = "anchor_destroy",
	[ERX_PROGRAM_GATE_UNREGISTER_IMAGE] = "gate_unregister_image",
	[ERX_PROGRAM_GATE_UNREGISTER_ANCHOR] = "gate_unregister_anchor",
	[ERX_PROGRAM_GROUP_CLOSE] = "group_close",
	[ERX_PROGRAM_BUDGET_DESTROY] = "budget_destroy",
	[ERX_PROGRAM_IRQ_UNBIND] = "irq_unbind",
	[ERX_PROGRAM_SINK_UNREGISTER] = "sink_unregister",
	[ERX_PROGRAM_IRQ_CLOSE] = "irq_close",
	[ERX_PROGRAM_DATA_DESTROY] = "data_destroy",
	[ERX_PROGRAM_BELL_DESTROY] = "bell_destroy",
	[ERX_PROGRAM_CHANNEL_UNMAP] = "channel_unmap",
	[ERX_PROGRAM_CHANNEL_DESTROY] = "channel_destroy",
	[ERX_PROGRAM_REPORT] = "report",
	[ERX_PROGRAM_STOP_ANCHOR] = "stop_anchor",
	[ERX_PROGRAM_CLOSE_PORT] = "close_port",
};
static const char *const phase_names[] = {
	[ERX_PROGRAM_RUNNING] = "running",
	[ERX_PROGRAM_FAULTED] = "faulted",
	[ERX_PROGRAM_ENDED] = "ended",
	[ERX_PROGRAM_RELEASED] = "released",
};

/* The ABI's values the test's model names, and the enums' names, so the test copies none of them. */
static void
constants(void)
{
	for (size_t i = 0; i < sizeof(act_names) / sizeof(act_names[0]); i++)
		printf("act %zu %s\n", i, act_names[i]);
	for (size_t i = 0; i < sizeof(phase_names) / sizeof(phase_names[0]); i++) {
		if (phase_names[i] != NULL)
			printf("phase %zu %s\n", i, phase_names[i]);
	}
	printf("const ok %d\nconst einval %d\nconst erange %d\nconst elimit %d\nconst step_failure %d\n",
	    ERX_OK, ERX_EINVAL, ERX_ERANGE, ERX_ELIMIT, STEP_FAILURE);
	printf("const exit_signal %" PRId64 "\nconst sigkill %d\nconst killed %" PRId64 "\n", ERX_EXIT_SIGNAL,
	    ERX_SIGKILL, ERX_PROGRAM_KILLED);
	printf("const exit_parent %" PRId64 "\nconst exit_released %" PRId64 "\nconst exit_nothread %" PRId64 "\n",
	    ERX_EXIT_PARENT, ERX_EXIT_RELEASED, ERX_EXIT_NOTHREAD);
	printf("const msg_caps %" PRIu32 "\n", ERX_MSG_CAPS);
	printf("const hr_dup %" PRIu32 "\nconst hr_give %" PRIu32 "\nconst hr_destroy %" PRIu32 "\n", ERX_HR_DUP,
	    ERX_HR_GIVE, ERX_HR_DESTROY);
	printf("const hr_alloc %" PRIu32 "\nconst hr_attach %" PRIu32 "\nconst hr_signal %" PRIu32 "\n", ERX_HR_ALLOC,
	    ERX_HR_ATTACH, ERX_HR_SIGNAL);
	printf("const prot_r %" PRIu32 "\nconst prot_rw %" PRIu32 "\n", ERX_PROT_R, ERX_PROT_RW);
	printf("const hr_read %" PRIu32 "\nconst hr_write %" PRIu32 "\nconst hr_map %" PRIu32 "\nconst hr_trigger %" PRIu32 "\n",
	    ERX_HR_READ, ERX_HR_WRITE, ERX_HR_MAP, ERX_HR_TRIGGER);
	for (size_t i = 0; i < sizeof(kinds) / sizeof(kinds[0]); i++)
		printf("signal %" PRIu32 " %d\n", kinds[i], erx_fault_signal(kinds[i]));
}

/* The install's copies and its passes. */
static void
installs(void)
{
	static const char *const install_names[ERX_PROGRAM_INSTALLS] = {
		[ERX_PROGRAM_ARG_BUDGET] = "budget",
		[ERX_PROGRAM_ARG_GROUP] = "group",
		[ERX_PROGRAM_ARG_OWN_SIDE] = "own_side",
		[ERX_PROGRAM_ARG_PEER_SIDE] = "peer_side",
		[ERX_PROGRAM_ARG_DOORBELL] = "doorbell",
		[ERX_PROGRAM_INSTALL_DATA] = "data",
	};

	for (uint32_t index = 0; index < ERX_PROGRAM_INSTALLS; index++)
		printf("install %" PRIu32 " %s %" PRIu32 "\n", index, install_names[index],
		    erx_program_install_rights(index));
	for (uint32_t index = 0; index <= ERX_PROGRAM_INSTALLS; index++)
		printf("prot %" PRIu32 " %s %" PRIu32 "\n", index,
		    index < ERX_PROGRAM_INSTALLS ? install_names[index] : "past", erx_program_session_prot(index));
	printf("install %" PRIu32 " past %" PRIu32 "\n", ERX_PROGRAM_INSTALLS,
	    erx_program_install_rights(ERX_PROGRAM_INSTALLS));
	for (uint32_t first = 0; first <= ERX_PROGRAM_INSTALLS + 1; first++)
		printf("batch %" PRIu32 " %" PRIu32 "\n", first, erx_program_install_batch(first));
}

int
main(void)
{
	constants();
	installs();
	specs();
	starts();
	ends();
	return (0);
}
