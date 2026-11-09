/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The generated reader of the widget server's records, fed what a hostile
 * writer of a renderer's standard input could send. The input is a stream:
 * records are read until one is refused or the stream ends inside one. Each
 * record read must lie within the input, and each list's texts must number
 * its count and lie within the record.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include <erx/ui_wire.h>

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void
check_lists(const erx_ui_record_t *record, const uint8_t *start, size_t size)
{
	const erx_ui_prop_t *prop;
	erx_ui_bytes_t text;
	uint32_t count, cursor;

	if (record->nprops > ERX_UI_PROPERTY_MAX ||
	    record->nremoved > ERX_UI_PROPERTY_MAX)
		abort();
	for (uint8_t index = 0; index < record->nprops; index++) {
		prop = &record->props[index];
		if (prop->form != ERX_UI_FORM_LIST || !prop->has_value)
			continue;
		count = 0;
		cursor = 0;
		while (erx_ui_list_next(prop, &cursor, &text)) {
			if (text.data < start ||
			    text.data + text.length > start + size)
				abort();
			count++;
		}
		if (count != prop->count || cursor != prop->bytes.length)
			abort();
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_ui_record_t record;
	size_t offset, used;

	for (offset = 0; offset < size; offset += used) {
		if (erx_ui_read(data + offset, size - offset, &record, &used) !=
		    ERX_UI_READ_OK)
			break;
		if (used < 5 || used > size - offset ||
		    used > ERX_UI_OP_MAX + 4)
			abort();
		check_lists(&record, data + offset, used);
	}
	return (0);
}
