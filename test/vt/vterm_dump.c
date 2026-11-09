/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The oracle side of erx_vt's differential test (docs/design-display.md,
 * "The oracle"): libvterm 0.3.3, built out of tree for the host, fed a
 * corpus script on standard input, writes the screen at each checkpoint
 * in the dump format of erx_vt:dump/1. The script is three commands, each
 * a line:
 *
 *	new COLS ROWS	a fresh terminal of that size, in UTF-8
 *	feed N		the next N bytes of standard input go to the terminal
 *	dump		the dump, then "reply HEX" (or "reply -") for the bytes
 *			the terminal answered since the last dump, then "end"
 *
 * libvterm's unicode.c is not built: this file supplies its two width
 * functions from the generated table of erx_vt_width, so the terminals
 * never differ on a width. It reads the pending wrap, the cursor's
 * visibility and the rows' continuation from libvterm's state, which its
 * public interface does not show, so it includes vterm_internal.h.
 *
 * The script is erXos's own corpus, not untrusted input, but a malformed
 * one still ends with a diagnostic and exit status 2, never a crash.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vterm.h"
#include "vterm_internal.h"

#include "erx/vt_width.h"

#define	MAX_COLS	640
#define	MAX_ROWS	256
#define	MAX_FEED	(1 << 24)
#define	MAX_REPLY	65536

INTERNAL int
vterm_unicode_width(uint32_t codepoint)
{

	return (erx_vt_width(codepoint));
}

INTERNAL int
vterm_unicode_is_combining(uint32_t codepoint)
{

	return (erx_vt_width(codepoint) == 0);
}

static unsigned char reply[MAX_REPLY];
static size_t reply_len;

static void
fail(const char *what)
{

	fprintf(stderr, "vterm_dump: %s\n", what);
	exit(2);
}

static void
on_output(const char *bytes, size_t len, void *user)
{

	(void)user;
	if (len > sizeof(reply) - reply_len)
		fail("replies past 64 KiB between dumps");
	memcpy(reply + reply_len, bytes, len);
	reply_len += len;
}

static void
put_colour(const VTermColor *colour, int fg)
{

	if (fg ? VTERM_COLOR_IS_DEFAULT_FG(colour) : VTERM_COLOR_IS_DEFAULT_BG(colour))
		putchar('-');
	else if (VTERM_COLOR_IS_INDEXED(colour))
		printf("%d", colour->indexed.idx);
	else
		printf("#%02x%02x%02x", colour->rgb.red, colour->rgb.green, colour->rgb.blue);
}

/* The attributes erx_vt keeps; libvterm has no dim. */
static void
put_cell(const VTermScreenCell *cell)
{
	const VTermScreenCellAttrs *a = &cell->attrs;
	char flags[16];
	size_t n = 0;

	if (cell->chars[0] == (uint32_t)-1) {
		putchar('-');
		return;
	}
	printf("%x", cell->chars[0] == 0 ? 0x20 : cell->chars[0]);
	for (int i = 1; i < VTERM_MAX_CHARS_PER_CELL && cell->chars[i] != 0; i++)
		printf("+%x", cell->chars[i]);
	if (a->bold)
		flags[n++] = 'b';
	if (a->italic)
		flags[n++] = 'i';
	if (a->blink)
		flags[n++] = 'k';
	if (a->reverse)
		flags[n++] = 'r';
	if (a->conceal)
		flags[n++] = 'h';
	if (a->strike)
		flags[n++] = 's';
	if (a->underline)
		flags[n++] = 'u';
	flags[n] = '\0';
	if (n == 0 && VTERM_COLOR_IS_DEFAULT_FG(&cell->fg) && VTERM_COLOR_IS_DEFAULT_BG(&cell->bg))
		return;
	printf("/%s:", n == 0 ? "-" : flags);
	put_colour(&cell->fg, 1);
	putchar(':');
	put_colour(&cell->bg, 0);
}

static void
dump(VTerm *vt)
{
	VTermScreen *screen = vterm_obtain_screen(vt);
	VTermState *state = vterm_obtain_state(vt);
	int rows, cols;

	vterm_get_size(vt, &rows, &cols);
	printf("size %d %d\n", cols, rows);
	printf("cursor %d %d %s %s\n", state->pos.row + 1, state->pos.col + 1,
	    state->at_phantom ? "wrap" : "-", state->mode.cursor_visible ? "shown" : "hidden");
	for (int row = 0; row < rows; row++) {
		int wrapped = row + 1 < rows && state->lineinfo[row + 1].continuation;

		printf("row %d %s", row + 1, wrapped ? "w" : "-");
		for (int col = 0; col < cols; col++) {
			VTermScreenCell cell;
			VTermPos pos = { .row = row, .col = col };

			/* get_cell stops copying at the first zero code point. */
			memset(&cell, 0, sizeof(cell));
			vterm_screen_get_cell(screen, pos, &cell);
			putchar(' ');
			put_cell(&cell);
		}
		putchar('\n');
	}
	if (reply_len == 0)
		printf("reply -\n");
	else {
		printf("reply ");
		for (size_t i = 0; i < reply_len; i++)
			printf("%02x", reply[i]);
		putchar('\n');
	}
	printf("end\n");
	reply_len = 0;
}

static VTerm *
terminal(int cols, int rows)
{
	VTerm *vt = vterm_new(rows, cols);
	VTermScreen *screen;

	if (vt == NULL)
		fail("vterm_new failed");
	vterm_set_utf8(vt, 1);
	vterm_output_set_callback(vt, on_output, NULL);
	screen = vterm_obtain_screen(vt);
	vterm_screen_enable_altscreen(screen, 1);
	vterm_screen_reset(screen, 1);
	reply_len = 0;
	return (vt);
}

int
main(void)
{
	VTerm *vt = NULL;
	char line[64];

	while (fgets(line, sizeof(line), stdin) != NULL) {
		int cols, rows;
		long n;
		char *bytes;

		if (strchr(line, '\n') == NULL)
			fail("command line too long");
		if (sscanf(line, "new %d %d", &cols, &rows) == 2) {
			if (cols < 2 || cols > MAX_COLS || rows < 1 || rows > MAX_ROWS)
				fail("size out of range");
			if (vt != NULL)
				vterm_free(vt);
			vt = terminal(cols, rows);
		} else if (sscanf(line, "feed %ld", &n) == 1) {
			if (vt == NULL || n < 0 || n > MAX_FEED)
				fail("feed without a terminal or out of range");
			if ((bytes = malloc(n == 0 ? 1 : (size_t)n)) == NULL)
				fail("out of memory");
			if (fread(bytes, 1, (size_t)n, stdin) != (size_t)n)
				fail("feed cut short");
			vterm_input_write(vt, bytes, (size_t)n);
			free(bytes);
		} else if (strcmp(line, "dump\n") == 0) {
			if (vt == NULL)
				fail("dump without a terminal");
			dump(vt);
		} else
			fail("unknown command");
	}
	if (vt != NULL)
		vterm_free(vt);
	return (fflush(stdout) == 0 ? 0 : 1);
}
