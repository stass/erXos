/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * LVGL's configuration for erx-lvgl (docs/design-display.md, "The widget
 * server"). Every option not set here keeps LVGL's default from
 * lv_conf_internal.h. What this file decides:
 *
 * - memory comes from the C library, so the host's sanitizers see every
 *   allocation;
 * - rows of a rendered area are LVGL's stride aligned to 32 bits, which is
 *   Plan 9's bytesperline for the channels erx-lvgl accepts;
 * - nothing animates: theme transitions take no time, so a pressed button
 *   changes once and an idle program runs no timer;
 * - no operating system layer, no file system, no image decoder, no log:
 *   the program reads only its standard input.
 */

#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_COLOR_FORMAT_DEFAULT		LV_COLOR_FORMAT_XRGB8888

#define LV_USE_STDLIB_MALLOC		LV_STDLIB_CLIB
#define LV_USE_STDLIB_STRING		LV_STDLIB_CLIB
#define LV_USE_STDLIB_SPRINTF		LV_STDLIB_CLIB

#define LV_USE_OS			LV_OS_NONE
#define LV_DRAW_BUF_STRIDE_ALIGN	4
#define LV_DRAW_BUF_ALIGN		4

#define LV_USE_LOG			0
#define LV_USE_ASSERT_NULL		1
#define LV_USE_ASSERT_MALLOC		1
#define LV_USE_SYSMON			0
#define LV_USE_PERF_MONITOR		0
#define LV_USE_MEM_MONITOR		0
/* A failed LVGL assertion ends the program, which the server sees, rather than spinning. */
#define LV_ASSERT_HANDLER		__builtin_trap();

#define LV_THEME_DEFAULT_TRANSITION_TIME 0
#define LV_TEXTAREA_DEF_PWD_SHOW_TIME	0

#define LV_USE_LODEPNG			0
#define LV_USE_LIBPNG			0
#define LV_USE_BMP			0
#define LV_USE_TJPGD			0
#define LV_USE_GIF			0
#define LV_USE_QRCODE			0
#define LV_USE_BARCODE			0

#define LV_BUILD_EXAMPLES		0
#define LV_BUILD_DEMOS			0
#define LV_USE_DEMO_WIDGETS		0

#endif /* !LV_CONF_H */
