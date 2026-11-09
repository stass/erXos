/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Reads a stream of the widget server's records from standard input with the
 * generated erx_ui_read() and prints one line per record naming what it read,
 * in the format of erx_ui_wire_tests:corpus/3 with numbers where that has
 * names, and every property's status block. Exits 1 at a refused record or a
 * stream that ends inside one.
 */

#include <stdio.h>
#include <stdlib.h>

#include <erx/ui_wire.h>

static void
print_hex(erx_ui_bytes_t bytes)
{
	putchar('x');
	for (uint32_t index = 0; index < bytes.length; index++)
		printf("%02x", bytes.data[index]);
}

static void
print_value(const erx_ui_prop_t *prop)
{
	erx_ui_bytes_t text;
	uint32_t cursor;

	if (!prop->has_value) {
		putchar('-');
		return;
	}
	switch (prop->form) {
	case ERX_UI_FORM_TEXT:
	case ERX_UI_FORM_BYTES:
		print_hex(prop->bytes);
		break;
	case ERX_UI_FORM_LIST:
		putchar('[');
		cursor = 0;
		for (uint16_t index = 0; erx_ui_list_next(prop, &cursor, &text);
		    index++) {
			if (index > 0)
				putchar(',');
			print_hex(text);
		}
		putchar(']');
		break;
	case ERX_UI_FORM_PRESENTATION:
		print_hex(prop->name);
		putchar(':');
		print_hex(prop->bytes);
		break;
	default:
		printf("%d", (int)prop->integer);
		break;
	}
}

static void
print_props(const erx_ui_record_t *record)
{
	const erx_ui_prop_t *prop;

	for (uint8_t index = 0; index < record->nprops; index++) {
		prop = &record->props[index];
		printf(" %u=%u,%u,%.*s,%u:", prop->number, prop->status,
		    prop->reporter, (int)prop->stopgap.length,
		    (const char *)prop->stopgap.data, prop->timeout_ms);
		print_value(prop);
	}
}

static void
print_record(const erx_ui_record_t *record)
{
	switch (record->tag) {
	case ERX_UI_INSERT:
		printf("insert %u %u %u %u", record->node, record->parent,
		    record->index, record->kind);
		print_props(record);
		break;
	case ERX_UI_SET:
		printf("set %u", record->node);
		print_props(record);
		printf(" /");
		for (uint8_t index = 0; index < record->nremoved; index++)
			printf(" %u", record->removed[index]);
		break;
	case ERX_UI_REMOVE:
		printf("remove %u", record->node);
		break;
	case ERX_UI_MOVE:
		printf("move %u %u", record->node, record->index);
		break;
	case ERX_UI_COMMIT:
		printf("commit");
		break;
	case ERX_UI_REPAINT:
		printf("repaint");
		break;
	case ERX_UI_SCREEN:
		printf("screen %u %u %u", record->width, record->height,
		    record->chan);
		break;
	case ERX_UI_INPUT:
		if (record->input == ERX_UI_INPUT_POINTER)
			printf("pointer %u %u %u", record->x, record->y,
			    record->buttons);
		else if (record->input == ERX_UI_INPUT_WHEEL)
			printf("wheel %d", record->steps);
		else if (record->rune == ERX_UI_RUNE_NONE)
			printf("key %s %u none", record->down ? "down" : "up",
			    record->code);
		else
			printf("key %s %u %u", record->down ? "down" : "up",
			    record->code, record->rune);
		break;
	}
	putchar('\n');
}

int
main(void)
{
	static uint8_t stream[64 << 20];
	erx_ui_record_t record;
	size_t length, offset, used;

	length = fread(stream, 1, sizeof(stream), stdin);
	if (length == sizeof(stream)) {
		fprintf(stderr, "stream too long\n");
		return (1);
	}
	for (offset = 0; offset < length; offset += used) {
		switch (erx_ui_read(stream + offset, length - offset, &record,
		    &used)) {
		case ERX_UI_READ_OK:
			print_record(&record);
			break;
		case ERX_UI_READ_MORE:
			fprintf(stderr, "stream ends inside a record at %zu\n",
			    offset);
			return (1);
		case ERX_UI_READ_BAD:
			fprintf(stderr, "refused at %zu: %s\n", offset,
			    record.reason);
			return (1);
		}
	}
	return (0);
}
