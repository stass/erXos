/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H
#define ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H

#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/core/dt.h"
#include "liberx/backend/fiasco/bcm2711_pins.h"
#include "liberx/backend/fiasco/entropy.h"
#include "erx/core/boot_args.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/pm_wdt.h"

/* include/erx/pack.h's; that header's erx_boot_inputs_t is the first stage's, not the boot page's. */
typedef struct erx_pack_view erx_pack_view_t;

/*
 * Accepts the firmware's device tree into *tree, once, before the root's service and
 * generator are up (docs/design-device-tree.md, "Facts into records"), and fills *seeds
 * from it: its /chosen seeds (erx_dt_seeds) and, when /chosen carries neither, the read
 * of the board's random generator that manifest gives the system domain
 * (erx_fiasco_rng200_read). The caller erases *seeds. Returns NULL, or why the root cannot
 * boot: the handoff carries no tree, the reader refused it, or the generator's row names
 * no node path. A root built without a program reads no tree: root_no_program.c leaves
 * *tree alone and gives no seeds.
 */
const char	*erx_fiasco_program_tree(erx_dt_t *tree, const erx_manifest_view_t *manifest, erx_fiasco_seeds_t *seeds);

/*
 * What the root found of a board device it drives itself (erx_fiasco_program_board):
 * the hardware watchdog or the firmware's mailbox.
 */
typedef enum erx_fiasco_found {
	/* The manifest gives the system domain none, as on QEMU virt. */
	ERX_FIASCO_FOUND_ABSENT = 1,
	/* Its row is confirmed by the tree, and the root opened it: its registers are mapped. */
	ERX_FIASCO_FOUND_READY,
	/* The tree does not confirm its row, or its page cannot be mapped: the board has none. */
	ERX_FIASCO_FOUND_UNCONFIRMED
} erx_fiasco_found_t;

/* What the root found and did of the board devices it drives itself (erx_fiasco_program_board). */
typedef struct erx_fiasco_board {
	/* The hardware watchdog, for the watchdog thread: no device unless watchdog_found is READY. */
	erx_fiasco_pm_wdt_t	watchdog;
	erx_fiasco_found_t	watchdog_found;
	erx_fiasco_found_t	mailbox_found;
	erx_fiasco_board_pins_t	pins;
	/* How many of the manifest's pins rows the root's write takes (board_pins). */
	uint32_t		pins_rows;
} erx_fiasco_board_t;

/*
 * The board devices the root drives itself, in the platform layer's place, but the RNG200,
 * which erx_fiasco_program_tree reads only when /chosen carries no seed; each through
 * the unit of its compatible string that manifest gives the system domain
 * (erx_boot_held_row) once tree, the one erx_fiasco_program_tree accepted, confirms its
 * row; *board says what was found and done:
 *   - the hardware watchdog (docs/design-platforms.md, "The watchdog"), of
 *     ERX_PM_WDT_COMPATIBLE, mapped into board->watchdog (erx_fiasco_pm_wdt_open), which
 *     has no device otherwise; nothing is written;
 *   - the firmware's mailbox (docs/design-fiasco.md, "The call table",
 *     erx_firmware_request), of ERX_VC_MAILBOX_COMPATIBLE, mapped by its shim
 *     (erx_fiasco_vc_mbox_open); nothing is written;
 *   - the on-board pins (docs/design-header-io.md, "On-board pins"): the manifest's
 *     pins rows of the pin controller of ERX_BCM2711_PINS_COMPATIBLE the system domain
 *     holds that set an on-board pin, bank 1 or 2, to a signal in a device's default
 *     state (erx_boot_pin_rows), set through that controller (erx_fiasco_bcm2711_pins_set).
 * The caller runs it before any domain starts, so no driver finds an on-board pin unset.
 * Returns NULL, or why the root cannot boot: a row's path is not a node path. A root built
 * without a program finds none of them and sets no pin.
 */
const char	*erx_fiasco_program_board(const erx_dt_t *tree, const erx_manifest_view_t *manifest,
		    erx_fiasco_board_t *board);

/*
 * What the root task runs once it is up: it joins tree's facts to the manifest's devices,
 * fills the boot information page, builds the domain library from the manifest and the
 * archive, pack, and enters musl's start path. tree is the one erx_fiasco_program_tree
 * accepted. Returns only on a refusal, with the reason. A root built without a program
 * answers this with root_no_program.c.
 */
const char	*erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *manifest,
	    const erx_pack_view_t *pack, const erx_dt_t *tree, const erx_boot_args_t *boot_args);

/*
 * Enters musl's start path with program as main and features as its AT_HWCAP and AT_HWCAP2,
 * on a stack of its own with a guard below it (docs/design-fiasco.md, "musl over the
 * backend"). Needs the root service running. A start that comes back ends the machine.
 */
_Noreturn void	 erx_fiasco_libc_root_start(int (*program)(int, char **, char **), erx_fiasco_cpu_features_t features);

#endif /* ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H */
