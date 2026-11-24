/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The arguments a creation writes into its domain's boot page
 * (docs/design-fiasco.md, "Boot information"), private to the domain
 * library: a pure function of the library, the plan and what each give's
 * steps made, which the apply phase (dom_apply.c) performs and the host
 * tests build alone.
 */

#ifndef LIBERX_SYSTEM_DOM_ARGS_H
#define LIBERX_SYSTEM_DOM_ARGS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/boot_words.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "liberx/backend/core/boot_info.h"

/*
 * One give of a creation in progress: the handles its steps made, by
 * device object, each value its installs took in the holder's table, and
 * how many of its steps were tried, the refused one included; and, by
 * device, whether its DMA memory reaches its holder's record, which the
 * give learns from the kernel once its steps succeed (apply_give).
 */
typedef struct erx_dom_give_made {
	uint64_t	made[ERX_DOM_OBJ_MADE_COUNT];	/* ERX_CAP_NULL for none */
	uint64_t	installed[ERX_DOM_OBJ_COUNT];
	/* Each MSI object's message, by its line, as its creation returned it. */
	erx_msi_message_t messages[ERX_DOM_UNIT_LINES_MAX];
	uint32_t	tried;
	bool		memory[ERX_DOM_DEVICES_MAX];
} erx_dom_give_made_t;

/*
 * The most runs of the arguments: the specification's own, -erx_record
 * build, a record per device, a -erx_record drive per drive, -erx_record
 * boot and -erx_record system_image.
 */
#define ERX_DOM_ARGS_RUNS_MAX	(4u + ERX_DOM_DEVICES_MAX + ERX_DOM_DRIVES_MAX)

/* The arguments' runs and the words of each record they point into. */
typedef struct erx_dom_args {
	erx_boot_words_t runs[ERX_DOM_ARGS_RUNS_MAX];
	char		given_words[ERX_DOM_DEVICES_MAX][ERX_BOOT_GIVEN_WORDS_MAX > ERX_BOOT_FUNCTION_WORDS_MAX ?
			    ERX_BOOT_GIVEN_WORDS_MAX : ERX_BOOT_FUNCTION_WORDS_MAX];
	char		drive_words[ERX_DOM_DRIVES_MAX][ERX_BOOT_DRIVE_WORDS_MAX];
	char		pair_words[ERX_BOOT_PAIR_WORDS_MAX];
	char		build_words[ERX_BOOT_BUILD_WORDS_MAX];
	char		system_image_words[ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX];
} erx_dom_args_t;

/*
 * Writes plan's boot page arguments into out, gives[i] what give i of the
 * plan made, and returns the number of runs in out->runs, or 0 when a
 * record does not fit.
 */
size_t		erx_dom_args(const erx_dom_lib_t *lib, const erx_dom_plan_t *plan,
		    const erx_dom_give_made_t *gives, erx_dom_args_t *out);

/*
 * The message of a PCIe function's line, device of a give that made
 * give: the one its MSI object's creation returned, zero for a wired line
 * and for none.
 */
erx_msi_message_t erx_dom_give_message(const erx_dom_give_made_t *give, const erx_dom_unit_device_t *device);

#endif /* LIBERX_SYSTEM_DOM_ARGS_H */
