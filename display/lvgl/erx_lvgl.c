/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx-lvgl: the LVGL renderer's native program (docs/design-display.md,
 * "The widget server" and "Kiosks and glasses"; docs/design-abi.md,
 * "Widget format").
 *
 * Standard input carries the widget server's records in ui.txt's binary
 * form: the screen record (the target's size and Plan 9 channel), the
 * operations of erx_ui_model:delta/2 ending in commit, input records and
 * repaint. Standard output carries what the program sends back in the same
 * form: an event record for each event on a node and each change of a
 * state value, and a pixels record for each rectangle LVGL renders.
 *
 * Data flow. The generated erx_ui_read() frames and checks each record;
 * apply_record() turns it into LVGL calls. A node is an LVGL object whose
 * user data is its ui_node_t, found by number through a hash table; a
 * node's entry is dropped by LVGL's delete event, so removing a subtree
 * drops every entry beneath it. LVGL renders in partial mode into a buffer
 * that sits inside the pixels record itself, at ERX_UI_PIXELS_AT, so a
 * flushed rectangle is written out with no copy.
 *
 * Invariants:
 * - nothing renders while a delta is open: between the first operation and
 *   its commit, LVGL's timers do not run, so no frame shows half a change;
 * - nothing runs while idle: the program blocks in poll() with the
 *   deadline lv_timer_handler() returns, or with none when no timer is due,
 *   and LVGL pauses its refresh and input timers when nothing changes;
 * - events caused by applying the server's own records are not reported,
 *   since the server already knows the value it set.
 *
 * Failure: a record the reader refuses, an operation that does not fit the
 * tree, an unsupported channel and a failed write each end the program
 * with a diagnostic on standard error and status 1; the widget server
 * treats the program's end as the renderer's. End of input ends it with
 * status 0.
 */

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <erx/ui_wire.h>

#include "lvgl.h"

/*
 * Plan 9's channel descriptor (draw(2), image(6)): each component a type
 * nibble and a bit-count nibble, the first component in the most
 * significant byte.
 */
#define CHAN_RED	0
#define CHAN_GREEN	1
#define CHAN_BLUE	2
#define CHAN_ALPHA	4
#define CHAN_IGNORE	6
#define DC(type, bits)	((uint32_t)(((type) & 15) << 4 | ((bits) & 15)))
#define CHAN3(a, b, c, d, e, f) \
	(DC(a, b) << 16 | DC(c, d) << 8 | DC(e, f))
#define CHAN4(a, b, c, d, e, f, g, h) \
	(DC(a, b) << 24 | DC(c, d) << 16 | DC(e, f) << 8 | DC(g, h))

/*
 * The channels erx-lvgl renders in. Plan 9 stores a pixel little-endian
 * with the first component in the high bits, which is LVGL's layout for
 * each of these formats, so a rendered row is already the channel's.
 */
static const struct channel {
	uint32_t		chan;
	lv_color_format_t	format;
} channels[] = {
	{ CHAN3(CHAN_RED, 5, CHAN_GREEN, 6, CHAN_BLUE, 5),
	    LV_COLOR_FORMAT_RGB565 },
	{ CHAN3(CHAN_RED, 8, CHAN_GREEN, 8, CHAN_BLUE, 8),
	    LV_COLOR_FORMAT_RGB888 },
	{ CHAN4(CHAN_IGNORE, 8, CHAN_RED, 8, CHAN_GREEN, 8, CHAN_BLUE, 8),
	    LV_COLOR_FORMAT_XRGB8888 },
	{ CHAN4(CHAN_ALPHA, 8, CHAN_RED, 8, CHAN_GREEN, 8, CHAN_BLUE, 8),
	    LV_COLOR_FORMAT_ARGB8888 },
};

/*
 * The pixels record LVGL draws into. The record starts 3 bytes into a
 * 16-byte aligned array, so its pixels, at the odd offset
 * ERX_UI_PIXELS_AT, start 16-byte aligned, which meets LV_DRAW_BUF_ALIGN.
 * LVGL's buffer is the room after the header in whole 32-bit words.
 */
#define REPORT_SLACK	(16 - ERX_UI_PIXELS_AT % 16)
#define PIXELS_ROOM	(ERX_UI_PIXELS_DATA_MAX & ~3U)
#define REPORT_SIZE	(ERX_UI_PIXELS_AT + PIXELS_ROOM)

static _Alignas(16) uint8_t report_space[REPORT_SLACK + REPORT_SIZE];
#define REPORT		(report_space + REPORT_SLACK)
#define LVGL_BUFFER	(REPORT + ERX_UI_PIXELS_AT)

/* The input: at most one whole record beyond what is consumed. */
static uint8_t input[ERX_UI_OP_MAX + 4];
static uint8_t event_record[ERX_UI_OP_MAX + 4];

typedef struct ui_node ui_node_t;
struct ui_node {
	lv_obj_t	*obj;
	lv_obj_t	*label;		/* a button's text, else NULL */
	char		*text;		/* the text property as shown, or NULL */
	char		*present;	/* the presentation as shown, or NULL */
	uint32_t	 id;
	int32_t		 width;		/* -1 when unset */
	int32_t		 height;	/* -1 when unset */
	int32_t		 own_width;	/* LVGL's width for the kind */
	int32_t		 own_height;	/* LVGL's height for the kind */
	int32_t		 min;
	int32_t		 max;
	int32_t		 value;
	uint8_t		 kind;
	uint8_t		 align;
	uint8_t		 columns;
};

/* Nodes by number: open addressing, linear probing, at most half full. */
static ui_node_t **table;
static size_t table_size;
static size_t table_count;

static lv_display_t *display;
static lv_indev_t *pointer, *keypad, *encoder;
static ui_node_t *root;
static bool applying;		/* events come from the server's records */
static bool uncommitted;	/* an operation since the last commit */
static uint64_t consumed;	/* input bytes read, for diagnostics */

static struct {
	lv_point_t	 point;
	bool		 pressed;
	uint32_t	 key;
	bool		 key_down;
	int16_t		 steps;
} in_state;

static void flush(lv_display_t *, const lv_area_t *, uint8_t *);

static void
fatal(const char *format, ...)
{
	va_list args;

	fputs("erx-lvgl: ", stderr);
	va_start(args, format);
	vfprintf(stderr, format, args);
	va_end(args);
	fputc('\n', stderr);
	exit(1);
}

static void
write_all(const uint8_t *bytes, size_t length)
{
	ssize_t written;

	while (length > 0) {
		written = write(STDOUT_FILENO, bytes, length);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0)
			fatal("write: %s", strerror(errno));
		bytes += written;
		length -= (size_t)written;
	}
}

static uint32_t
tick_ms(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)((uint64_t)now.tv_sec * 1000 +
	    (uint64_t)now.tv_nsec / 1000000);
}

/* The node table. */

static size_t
slot_of(uint32_t id)
{
	return (size_t)(id * 2654435761U) & (table_size - 1);
}

static ui_node_t *
node_find(uint32_t id)
{
	size_t slot;

	if (table_size == 0)
		return NULL;
	for (slot = slot_of(id); table[slot] != NULL;
	    slot = (slot + 1) & (table_size - 1))
		if (table[slot]->id == id)
			return table[slot];
	return NULL;
}

static void
table_put(ui_node_t *node)
{
	ui_node_t **old = table;
	size_t old_size = table_size, slot;

	if (2 * (table_count + 1) > table_size) {
		table_size = old_size == 0 ? 64 : 2 * old_size;
		table = calloc(table_size, sizeof(*table));
		if (table == NULL)
			fatal("out of memory for %zu nodes", table_count + 1);
		table_count = 0;
		for (size_t index = 0; index < old_size; index++)
			if (old[index] != NULL)
				table_put(old[index]);
		free(old);
	}
	for (slot = slot_of(node->id); table[slot] != NULL;
	    slot = (slot + 1) & (table_size - 1))
		;
	table[slot] = node;
	table_count++;
}

/* Removes a node, shifting back the entries its slot displaced. */
static void
table_remove(uint32_t id)
{
	size_t hole, slot, home;

	for (hole = slot_of(id); table[hole]->id != id;
	    hole = (hole + 1) & (table_size - 1))
		;
	table[hole] = NULL;
	table_count--;
	for (slot = (hole + 1) & (table_size - 1); table[slot] != NULL;
	    slot = (slot + 1) & (table_size - 1)) {
		home = slot_of(table[slot]->id);
		/* Move the entry into the hole unless its home lies after the hole. */
		if (((slot - home) & (table_size - 1)) >=
		    ((slot - hole) & (table_size - 1))) {
			table[hole] = table[slot];
			table[slot] = NULL;
			hole = slot;
		}
	}
}

/* Events. */

static void
send_event(const ui_node_t *node, uint8_t event, const erx_ui_detail_t *detail)
{
	size_t length;

	length = erx_ui_write_event(event_record, sizeof(event_record),
	    node->id, event, detail);
	if (length == 0)
		fatal("cannot write event %u of node %u", event, node->id);
	write_all(event_record, length);
}

static void
send_plain(const ui_node_t *node, uint8_t event)
{
	const erx_ui_detail_t none = { .tag = ERX_UI_DETAIL_NONE };

	send_event(node, event, &none);
}

static void
send_integer(const ui_node_t *node, uint8_t event, uint8_t tag, int32_t value)
{
	const erx_ui_detail_t detail = { .tag = tag, .integer = value };

	send_event(node, event, &detail);
}

static void
send_text(const ui_node_t *node, uint8_t event, const char *text)
{
	const erx_ui_detail_t detail = {
		.tag = ERX_UI_DETAIL_TEXT,
		.text = { (const uint8_t *)text, (uint32_t)strlen(text) },
	};

	send_event(node, event, &detail);
}

/*
 * Every event on a node and every change of a state value goes to the
 * server, which decides with erx_ui_model:hit/4 whether the node takes it.
 */
static void
on_lvgl_event(lv_event_t *event)
{
	ui_node_t *node = lv_event_get_user_data(event);
	lv_event_code_t code = lv_event_get_code(event);

	if (applying)
		return;
	switch (code) {
	case LV_EVENT_CLICKED:
		if (node->kind == ERX_UI_KIND_BUTTON)
			send_plain(node, ERX_UI_PROP_ON_CLICK);
		if (node->present != NULL)
			send_plain(node, ERX_UI_PROP_ON_SELECT);
		break;
	case LV_EVENT_VALUE_CHANGED:
		switch (node->kind) {
		case ERX_UI_KIND_CHECKBOX:
			send_integer(node, ERX_UI_PROP_ON_CHANGE,
			    ERX_UI_DETAIL_BOOLEAN,
			    lv_obj_has_state(node->obj, LV_STATE_CHECKED));
			break;
		case ERX_UI_KIND_SLIDER:
			send_integer(node, ERX_UI_PROP_ON_CHANGE,
			    ERX_UI_DETAIL_INTEGER, lv_slider_get_value(node->obj));
			break;
		case ERX_UI_KIND_INPUT:
			send_text(node, ERX_UI_PROP_ON_CHANGE,
			    lv_textarea_get_text(node->obj));
			break;
		case ERX_UI_KIND_LIST:
			send_integer(node, ERX_UI_PROP_ON_CHANGE,
			    ERX_UI_DETAIL_INTEGER,
			    (int32_t)lv_dropdown_get_selected(node->obj));
			break;
		}
		break;
	case LV_EVENT_READY:
		if (node->kind == ERX_UI_KIND_INPUT)
			send_text(node, ERX_UI_PROP_ON_SUBMIT,
			    lv_textarea_get_text(node->obj));
		break;
	default:
		break;
	}
}

/*
 * A node ends with its object. LVGL sends LV_EVENT_DELETE to each object
 * of a deleted subtree and then drops that object's callbacks, so no
 * later callback sees the freed node.
 */
static void
on_lvgl_delete(lv_event_t *event)
{
	ui_node_t *node = lv_event_get_user_data(event);

	table_remove(node->id);
	if (node == root)
		root = NULL;
	free(node->text);
	free(node->present);
	free(node);
}

/* Nodes. */

static bool
takes_children(uint8_t kind)
{
	return kind >= ERX_UI_KIND_COLUMN && kind <= ERX_UI_KIND_STACK;
}

/* A plain container: no theme style, laid out by its kind. */
static lv_obj_t *
container(lv_obj_t *parent, uint8_t kind)
{
	lv_obj_t *obj = lv_obj_create(parent);

	lv_obj_remove_style_all(obj);
	switch (kind) {
	case ERX_UI_KIND_COLUMN:
	case ERX_UI_KIND_SCROLL:
		lv_obj_set_flex_flow(obj, LV_FLEX_FLOW_COLUMN);
		break;
	case ERX_UI_KIND_ROW:
		lv_obj_set_flex_flow(obj, LV_FLEX_FLOW_ROW);
		break;
	case ERX_UI_KIND_GRID:
		lv_obj_set_flex_flow(obj, LV_FLEX_FLOW_ROW_WRAP);
		break;
	default:
		break;
	}
	if (kind != ERX_UI_KIND_SCROLL)
		lv_obj_set_scrollable(obj, false);
	lv_obj_set_size(obj, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
	return obj;
}

static lv_obj_t *
widget(lv_obj_t *parent, ui_node_t *node)
{
	lv_obj_t *obj;

	switch (node->kind) {
	case ERX_UI_KIND_LABEL:
	case ERX_UI_KIND_IMAGE:
		return lv_label_create(parent);
	case ERX_UI_KIND_BUTTON:
		obj = lv_button_create(parent);
		node->label = lv_label_create(obj);
		lv_label_set_text_static(node->label, "");
		lv_obj_center(node->label);
		return obj;
	case ERX_UI_KIND_CHECKBOX:
		obj = lv_checkbox_create(parent);
		lv_checkbox_set_text_static(obj, "");
		return obj;
	case ERX_UI_KIND_SLIDER:
		return lv_slider_create(parent);
	case ERX_UI_KIND_INPUT:
		obj = lv_textarea_create(parent);
		lv_textarea_set_one_line(obj, true);
		lv_textarea_set_max_length(obj, 4096);
		lv_obj_set_style_anim_duration(obj, 0, LV_PART_CURSOR);
		return obj;
	case ERX_UI_KIND_LIST:
		return lv_dropdown_create(parent);
	case ERX_UI_KIND_SPACER:
		return container(parent, ERX_UI_KIND_SPACER);
	default:
		return container(parent, node->kind);
	}
}

static ui_node_t *
parent_node(const ui_node_t *node)
{
	return lv_obj_get_user_data(lv_obj_get_parent(node->obj));
}

/*
 * A node's size: its width and height properties when set; otherwise
 * align fill stretches it to its parent's size (both axes for the
 * root and a stack's children) on the axis across a column's or a row's
 * flow, a grid gives each child its share of the
 * row, and anything else keeps its own size.
 */
static void
node_size(ui_node_t *node)
{
	const ui_node_t *parent = parent_node(node);
	uint8_t parent_kind = parent == NULL ? ERX_UI_KIND_STACK : parent->kind;
	bool fill = node->align == ERX_UI_ALIGN_FILL;
	bool stretch_width = parent_kind != ERX_UI_KIND_ROW;
	bool stretch_height = parent_kind == ERX_UI_KIND_ROW ||
	    parent_kind == ERX_UI_KIND_STACK;

	if (node->width >= 0)
		lv_obj_set_width(node->obj, node->width);
	else if (parent_kind == ERX_UI_KIND_GRID)
		lv_obj_set_width(node->obj, LV_PCT(100 / parent->columns));
	else if (fill && stretch_width)
		lv_obj_set_width(node->obj, LV_PCT(100));
	else
		lv_obj_set_width(node->obj, node->own_width);
	if (node->height >= 0)
		lv_obj_set_height(node->obj, node->height);
	else if (fill && stretch_height)
		lv_obj_set_height(node->obj, LV_PCT(100));
	else
		lv_obj_set_height(node->obj, node->own_height);
}

static void
children_size(ui_node_t *node)
{
	uint32_t count = lv_obj_get_child_count(node->obj);

	for (uint32_t index = 0; index < count; index++)
		node_size(lv_obj_get_user_data(lv_obj_get_child(node->obj,
		    (int32_t)index)));
}

static const char *const status_names[] = {
	"ok", "partial", "unknown", "unsupported", "timeout", "error",
};

/*
 * A text or presentation property as shown: its value, then its status
 * in brackets when the status is not ok, or the status alone when there
 * is no value.
 */
static char *
shown_text(const erx_ui_prop_t *prop)
{
	const char *status = prop->status < sizeof(status_names) /
	    sizeof(status_names[0]) ? status_names[prop->status] : "error";
	size_t length = prop->has_value ? prop->bytes.length : 0;
	char *text = malloc(length + 16);

	if (text == NULL)
		fatal("out of memory for a text of %zu bytes", length);
	if (prop->has_value)
		memcpy(text, prop->bytes.data, length);
	text[length] = '\0';
	if (prop->status != ERX_UI_STATUS_OK)
		snprintf(text + length, 16, "%s[%s]", length > 0 ? " " : "",
		    status);
	return text;
}

static void
show_text(ui_node_t *node)
{
	const char *text = node->present != NULL ? node->present :
	    node->text != NULL ? node->text : "";

	switch (node->kind) {
	case ERX_UI_KIND_LABEL:
		lv_label_set_text(node->obj, text);
		break;
	case ERX_UI_KIND_BUTTON:
		lv_label_set_text(node->label, text);
		break;
	case ERX_UI_KIND_CHECKBOX:
		lv_checkbox_set_text(node->obj, text);
		break;
	case ERX_UI_KIND_INPUT:
		lv_textarea_set_text(node->obj, text);
		break;
	default:
		break;
	}
}

/*
 * A list's items as LVGL's options, one per line. Each item's text takes a
 * 4-byte length in the encoding, so the options are shorter than it.
 */
static void
set_items(ui_node_t *node, const erx_ui_prop_t *prop)
{
	erx_ui_bytes_t item;
	uint32_t cursor = 0;
	size_t length = 0;
	char *options = malloc((size_t)prop->bytes.length + 1);

	if (options == NULL)
		fatal("out of memory for %u items", prop->count);
	while (erx_ui_list_next(prop, &cursor, &item)) {
		if (length > 0)
			options[length++] = '\n';
		for (uint32_t index = 0; index < item.length; index++)
			options[length++] = item.data[index] == '\n' ? ' ' :
			    (char)item.data[index];
	}
	options[length] = '\0';
	lv_dropdown_set_options(node->obj, options);
	free(options);
}

static void
set_slider(ui_node_t *node)
{
	lv_slider_set_range(node->obj, node->min, node->max);
	lv_slider_set_value(node->obj, node->value, LV_ANIM_OFF);
}

/*
 * Sets one property to prop's value, or with prop NULL clears it. The node's
 * kind takes the property (set_props checks), so each case may call the
 * LVGL setter of the kind's widget.
 */
static void
set_prop(ui_node_t *node, uint8_t number, const erx_ui_prop_t *prop)
{
	bool cleared = prop == NULL;
	int32_t integer = cleared ? 0 : prop->integer;

	switch (number) {
	case ERX_UI_PROP_WIDTH:
		node->width = cleared ? -1 : integer;
		node_size(node);
		break;
	case ERX_UI_PROP_HEIGHT:
		node->height = cleared ? -1 : integer;
		node_size(node);
		break;
	case ERX_UI_PROP_WEIGHT:
		lv_obj_set_flex_grow(node->obj, (uint8_t)integer);
		break;
	case ERX_UI_PROP_PAD:
		lv_obj_set_style_pad_all(node->obj, integer, 0);
		break;
	case ERX_UI_PROP_ALIGN:
		node->align = cleared ? ERX_UI_ALIGN_FILL : (uint8_t)integer;
		node_size(node);
		break;
	case ERX_UI_PROP_VISIBLE:
		lv_obj_set_hidden(node->obj,
		    !cleared && integer == 0);
		break;
	case ERX_UI_PROP_ENABLED:
		lv_obj_set_disabled(node->obj,
		    !cleared && integer == 0);
		break;
	case ERX_UI_PROP_PRESENT:
		free(node->present);
		node->present = cleared ? NULL : shown_text(prop);
		lv_obj_set_clickable(node->obj,
		    node->present != NULL || (node->kind != ERX_UI_KIND_LABEL &&
		    node->kind != ERX_UI_KIND_IMAGE));
		show_text(node);
		break;
	case ERX_UI_PROP_TEXT:
	case ERX_UI_PROP_ALT:
		free(node->text);
		node->text = cleared ? NULL : shown_text(prop);
		show_text(node);
		break;
	case ERX_UI_PROP_PLACEHOLDER: {
		char *text = cleared ? NULL : shown_text(prop);

		lv_textarea_set_placeholder_text(node->obj,
		    text == NULL ? "" : text);
		free(text);
		break;
	}
	case ERX_UI_PROP_SECRET:
		lv_textarea_set_password_mode(node->obj, integer != 0);
		break;
	case ERX_UI_PROP_CHECKED:
		lv_obj_set_checked(node->obj, integer != 0);
		break;
	case ERX_UI_PROP_MIN:
		node->min = cleared ? 0 : integer;
		break;
	case ERX_UI_PROP_MAX:
		node->max = cleared ? 100 : integer;
		break;
	case ERX_UI_PROP_VALUE:
		node->value = cleared ? node->min : integer;
		break;
	case ERX_UI_PROP_ITEMS:
		if (cleared)
			lv_dropdown_clear_options(node->obj);
		else
			set_items(node, prop);
		break;
	case ERX_UI_PROP_SELECTED:
		lv_dropdown_set_selected(node->obj, (uint32_t)integer);
		break;
	case ERX_UI_PROP_COLUMNS:
		node->columns = cleared ? 1 : (uint8_t)integer;
		children_size(node);
		break;
	default:
		/* Events, images and keys change nothing a renderer shows. */
		break;
	}
}

/*
 * The properties of a record, set on its node. Every property and removal
 * is checked first against the node's kind (erx_ui_takes, generated from
 * ui.txt), so set_prop() is only ever given one the kind takes.
 */
static void
set_props(ui_node_t *node, const erx_ui_record_t *record)
{
	for (uint8_t index = 0; index < record->nprops; index++)
		if (!erx_ui_takes(node->kind, record->props[index].number))
			fatal("node %u of kind %u does not take property %u",
			    node->id, node->kind, record->props[index].number);
	for (uint8_t index = 0; index < record->nremoved; index++)
		if (!erx_ui_takes(node->kind, record->removed[index]))
			fatal("node %u of kind %u does not take property %u",
			    node->id, node->kind, record->removed[index]);
	for (uint8_t index = 0; index < record->nprops; index++)
		set_prop(node, record->props[index].number,
		    &record->props[index]);
	for (uint8_t index = 0; index < record->nremoved; index++)
		set_prop(node, record->removed[index], NULL);
	if (node->kind == ERX_UI_KIND_SLIDER)
		set_slider(node);
}

static ui_node_t *
node_fetch(uint32_t id)
{
	ui_node_t *node = node_find(id);

	if (node == NULL)
		fatal("record at byte %llu names node %u, which does not exist",
		    (unsigned long long)consumed, id);
	return node;
}

static void
insert(const erx_ui_record_t *record)
{
	lv_obj_t *parent_obj;
	ui_node_t *parent = NULL, *node;

	if (node_find(record->node) != NULL)
		fatal("insert of node %u, which exists", record->node);
	if (record->parent == 0) {
		if (root != NULL)
			fatal("insert of root %u beside root %u", record->node,
			    root->id);
		parent_obj = lv_screen_active();
	} else {
		parent = node_fetch(record->parent);
		if (!takes_children(parent->kind))
			fatal("insert of node %u under node %u, which takes no "
			    "children", record->node, parent->id);
		parent_obj = parent->obj;
	}
	if (record->index > lv_obj_get_child_count(parent_obj))
		fatal("insert of node %u at %u past its parent's children",
		    record->node, record->index);
	node = calloc(1, sizeof(*node));
	if (node == NULL)
		fatal("out of memory for node %u", record->node);
	*node = (ui_node_t){
		.id = record->node, .kind = record->kind, .width = -1,
		.height = -1, .min = 0, .max = 100, .value = 0,
		.align = ERX_UI_ALIGN_FILL, .columns = 1,
	};
	node->obj = widget(parent_obj, node);
	node->own_width = lv_obj_get_style_width(node->obj, 0);
	node->own_height = lv_obj_get_style_height(node->obj, 0);
	lv_obj_set_user_data(node->obj, node);
	lv_obj_add_event_cb(node->obj, on_lvgl_event, LV_EVENT_ALL, node);
	lv_obj_add_event_cb(node->obj, on_lvgl_delete, LV_EVENT_DELETE, node);
	table_put(node);
	if (record->parent == 0)
		root = node;
	lv_obj_move_to_index(node->obj, record->index);
	node_size(node);
	set_props(node, record);
}

static void
move(const erx_ui_record_t *record)
{
	ui_node_t *node = node_fetch(record->node);
	lv_obj_t *parent = lv_obj_get_parent(node->obj);

	if (record->index >= lv_obj_get_child_count(parent))
		fatal("move of node %u to %u past its parent's children",
		    node->id, record->index);
	lv_obj_move_to_index(node->obj, record->index);
}

/*
 * Plan 9's rows of a rectangle are the 32-bit words covering it, counted
 * from the word that holds its left edge (bytesperline in draw(2)). LVGL's
 * rows are the rectangle's pixels padded to a word. The two agree when the
 * left edge starts a word, so each area LVGL invalidates, already clipped
 * to the screen, has its left edge moved down to one: to an even pixel at
 * 16 bits, a multiple of 4 at 24, any pixel at 32.
 */
static void
word_align(lv_event_t *event)
{
	lv_area_t *area = lv_event_get_param(event);
	uint32_t size = lv_color_format_get_size(
	    lv_display_get_color_format(display));
	int32_t pixels = size == 2 ? 2 : size == 3 ? 4 : 1;

	area->x1 -= area->x1 % pixels;
}

/* The target's size and channel, at start and on every change. */
static void
screen(const erx_ui_record_t *record)
{
	lv_color_format_t format = LV_COLOR_FORMAT_UNKNOWN;

	for (size_t index = 0; index < sizeof(channels) / sizeof(channels[0]);
	    index++)
		if (channels[index].chan == record->chan)
			format = channels[index].format;
	if (format == LV_COLOR_FORMAT_UNKNOWN)
		fatal("channel 0x%08x is not one erx-lvgl renders in",
		    record->chan);
	if (record->width == 0 || record->height == 0 ||
	    lv_draw_buf_width_to_stride(record->width, format) > PIXELS_ROOM)
		fatal("a screen of %ux%u does not fit a pixels report by rows",
		    record->width, record->height);
	if (display != NULL) {
		lv_display_set_color_format(display, format);
		lv_display_set_resolution(display, record->width,
		    record->height);
		lv_obj_invalidate(lv_screen_active());
		return;
	}
	display = lv_display_create(record->width, record->height);
	lv_display_set_color_format(display, format);
	lv_display_set_buffers(display, LVGL_BUFFER, NULL, PIXELS_ROOM,
	    LV_DISPLAY_RENDER_MODE_PARTIAL);
	lv_display_set_flush_cb(display, flush);
	lv_display_add_event_cb(display, word_align, LV_EVENT_INVALIDATE_AREA,
	    NULL);
	lv_indev_set_display(pointer, display);
	lv_indev_set_display(keypad, display);
	lv_indev_set_display(encoder, display);
	lv_obj_set_scrollable(lv_screen_active(), false);
}

static void
apply_record(const erx_ui_record_t *record)
{
	if (display == NULL && record->tag != ERX_UI_SCREEN)
		fatal("record %u at byte %llu before the screen record",
		    record->tag, (unsigned long long)consumed);
	applying = true;
	switch (record->tag) {
	case ERX_UI_INSERT:
		insert(record);
		uncommitted = true;
		break;
	case ERX_UI_REMOVE:
		lv_obj_delete(node_fetch(record->node)->obj);
		uncommitted = true;
		break;
	case ERX_UI_SET:
		set_props(node_fetch(record->node), record);
		uncommitted = true;
		break;
	case ERX_UI_MOVE:
		move(record);
		uncommitted = true;
		break;
	case ERX_UI_COMMIT:
		uncommitted = false;
		break;
	case ERX_UI_SCREEN:
		screen(record);
		break;
	case ERX_UI_REPAINT:
		lv_obj_invalidate(lv_screen_active());
		break;
	default:
		break;
	}
	applying = false;
}

/* Input. */

/*
 * A character as LVGL's key: its UTF-8 bytes packed little-endian, as
 * lv_textarea_add_char() reads them. A private-use rune no table above
 * maps (a special key) is no character, and is 0, which is dropped.
 */
static uint32_t
utf8_key(uint32_t rune)
{
	if (rune >= 0xe000 && rune <= 0xf8ff)
		return 0;
	if (rune < 0x80)
		return rune;
	if (rune < 0x800)
		return (0xc0 | rune >> 6) | (0x80 | (rune & 0x3f)) << 8;
	if (rune < 0x10000)
		return (0xe0 | rune >> 12) | (0x80 | (rune >> 6 & 0x3f)) << 8 |
		    (0x80 | (rune & 0x3f)) << 16;
	return (0xf0 | rune >> 18) | (0x80 | (rune >> 12 & 0x3f)) << 8 |
	    (0x80 | (rune >> 6 & 0x3f)) << 16 | (uint32_t)(0x80 | (rune & 0x3f)) << 24;
}

/*
 * A key's rune as LVGL's key: control characters and Plan 9's private-use
 * runes for the cursor keys (keyboard(6)); any other rune is itself.
 */
static uint32_t
lvgl_key(uint32_t rune)
{
	switch (rune) {
	case '\n':
	case '\r':
		return LV_KEY_ENTER;
	case 0x1b:
		return LV_KEY_ESC;
	case '\b':
		return LV_KEY_BACKSPACE;
	case 0x7f:
		return LV_KEY_DEL;
	case '\t':
		return LV_KEY_NEXT;
	case 0xf00e:
		return LV_KEY_UP;
	case 0x80:
		return LV_KEY_DOWN;
	case 0xf011:
		return LV_KEY_LEFT;
	case 0xf012:
		return LV_KEY_RIGHT;
	case 0xf00d:
		return LV_KEY_HOME;
	case 0xf018:
		return LV_KEY_END;
	default:
		return utf8_key(rune);
	}
}

/*
 * LVGL's keypad holds one key and acts on its press. A down while another
 * key is held releases that key first, so fast typing loses nothing; an
 * up releases the held key when it is that key or has no rune, and is
 * otherwise stale.
 */
static void
key_record(const erx_ui_record_t *record)
{
	uint32_t key = record->rune == ERX_UI_RUNE_NONE ? 0 :
	    lvgl_key(record->rune);

	if (record->down && key == 0)
		return;
	if (in_state.key_down && (record->down || key == 0 ||
	    key == in_state.key)) {
		in_state.key_down = false;
		lv_indev_read(keypad);
	}
	if (record->down) {
		in_state.key = key;
		in_state.key_down = true;
		lv_indev_read(keypad);
	}
}

static void
input_record(const erx_ui_record_t *record)
{
	switch (record->input) {
	case ERX_UI_INPUT_POINTER:
		in_state.point.x = record->x;
		in_state.point.y = record->y;
		in_state.pressed = (record->buttons & 1) != 0;
		lv_indev_read(pointer);
		break;
	case ERX_UI_INPUT_KEY:
		key_record(record);
		break;
	case ERX_UI_INPUT_WHEEL:
		in_state.steps = record->steps;
		lv_indev_read(encoder);
		break;
	}
}

static void
read_pointer(lv_indev_t *indev, lv_indev_data_t *data)
{
	(void)indev;
	data->point = in_state.point;
	data->state = in_state.pressed ? LV_INDEV_STATE_PRESSED :
	    LV_INDEV_STATE_RELEASED;
}

static void
read_keypad(lv_indev_t *indev, lv_indev_data_t *data)
{
	(void)indev;
	data->key = in_state.key;
	data->state = in_state.key_down ? LV_INDEV_STATE_PRESSED :
	    LV_INDEV_STATE_RELEASED;
}

static void
read_encoder(lv_indev_t *indev, lv_indev_data_t *data)
{
	(void)indev;
	data->enc_diff = in_state.steps;
	data->state = LV_INDEV_STATE_RELEASED;
	in_state.steps = 0;
}

static lv_indev_t *
event_driven(lv_indev_type_t type, lv_indev_read_cb_t read)
{
	lv_indev_t *indev = lv_indev_create();

	lv_indev_set_type(indev, type);
	lv_indev_set_read_cb(indev, read);
	lv_indev_set_mode(indev, LV_INDEV_MODE_EVENT);
	return indev;
}

/* Output. */

/*
 * LVGL renders each area into LVGL_BUFFER, which is the pixels of the
 * report record, so the record is written around them in place.
 */
static void
flush(lv_display_t *disp, const lv_area_t *area, uint8_t *pixels)
{
	uint32_t width = (uint32_t)lv_area_get_width(area);
	uint32_t height = (uint32_t)lv_area_get_height(area);
	size_t length = (size_t)lv_draw_buf_width_to_stride(width,
	    lv_display_get_color_format(disp)) * height;
	size_t written;

	if (pixels != LVGL_BUFFER)
		fatal("LVGL flushed from outside its buffer");
	written = erx_ui_write_pixels(REPORT, REPORT_SIZE, (uint16_t)area->x1,
	    (uint16_t)area->y1, (uint16_t)width, (uint16_t)height, pixels,
	    length);
	if (written == 0)
		fatal("a flushed area of %ux%u does not fit a pixels report",
		    width, height);
	write_all(REPORT, written);
	lv_display_flush_ready(disp);
}

/* The records whole in input[0..*have), applied; the rest moved first. */
static void
consume(size_t *have)
{
	erx_ui_record_t record;
	size_t start = 0, used;

	while (start < *have) {
		switch (erx_ui_read(input + start, *have - start, &record,
		    &used)) {
		case ERX_UI_READ_MORE:
			memmove(input, input + start, *have - start);
			*have -= start;
			return;
		case ERX_UI_READ_BAD:
			fatal("refused the record at byte %llu: %s",
			    (unsigned long long)consumed, record.reason);
			/* NOTREACHED */
		case ERX_UI_READ_OK:
			if (record.tag == ERX_UI_INPUT && display != NULL) {
				lv_obj_update_layout(lv_screen_active());
				input_record(&record);
			}
			else
				apply_record(&record);
			start += used;
			consumed += used;
			break;
		}
	}
	*have = 0;
}

int
main(void)
{
	struct pollfd in = { .fd = STDIN_FILENO, .events = POLLIN };
	size_t have = 0;
	ssize_t got;
	uint32_t next;
	int timeout;

	signal(SIGPIPE, SIG_IGN);
	lv_init();
	lv_tick_set_cb(tick_ms);
	pointer = event_driven(LV_INDEV_TYPE_POINTER, read_pointer);
	keypad = event_driven(LV_INDEV_TYPE_KEYPAD, read_keypad);
	encoder = event_driven(LV_INDEV_TYPE_ENCODER, read_encoder);
	lv_group_set_default(lv_group_create());
	lv_indev_set_group(keypad, lv_group_get_default());
	lv_indev_set_group(encoder, lv_group_get_default());
	for (;;) {
		timeout = -1;
		if (display != NULL && !uncommitted) {
			next = lv_timer_handler();
			if (next != LV_NO_TIMER_READY)
				timeout = next > INT_MAX ? INT_MAX : (int)next;
		}
		if (poll(&in, 1, timeout) < 0) {
			if (errno == EINTR)
				continue;
			fatal("poll: %s", strerror(errno));
		}
		if ((in.revents & POLLNVAL) != 0)
			fatal("standard input is not open");
		if ((in.revents & (POLLIN | POLLHUP | POLLERR)) == 0)
			continue;
		got = read(STDIN_FILENO, input + have, sizeof(input) - have);
		if (got < 0 && errno == EINTR)
			continue;
		if (got < 0)
			fatal("read: %s", strerror(errno));
		if (got == 0) {
			if (have > 0)
				fatal("input ends inside the record at byte %llu",
				    (unsigned long long)consumed);
			return 0;
		}
		have += (size_t)got;
		consume(&have);
	}
}
