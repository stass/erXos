/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lookups by text, over the generated table. This is the one source that includes it.
 */

#include "erx_device_core.h"

#include "erx/hw/device_table.h"

static bool
same_text(const char *name, const char *text, size_t length)
{
	size_t at = 0;

	while (at < length && name[at] != '\0' && name[at] == text[at])
		at++;
	return (at == length && name[at] == '\0');
}

static size_t
text_length(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (length);
}

const erx_device_peripheral_t *
erx_device_peripheral_find(const char *name, size_t length)
{
	for (size_t index = 0; index < sizeof(erx_device_peripherals) / sizeof(erx_device_peripherals[0]); index++) {
		if (same_text(erx_device_peripherals[index].name, name, length))
			return (&erx_device_peripherals[index]);
	}
	return (NULL);
}

uint32_t
erx_device_register_named(const erx_device_peripheral_t *peripheral, const char *name)
{
	const size_t length = text_length(name);
	uint32_t index = 0;

	while (index < peripheral->register_count && !same_text(peripheral->registers[index].name, name, length))
		index++;
	return (index);
}

uint32_t
erx_device_field_named(const erx_device_peripheral_t *peripheral, const erx_device_register_t *reg, const char *name)
{
	const size_t length = text_length(name);
	uint32_t index = 0;

	while (index < reg->field_count && !same_text(peripheral->fields[reg->first_field + index].name, name, length))
		index++;
	return (index);
}
