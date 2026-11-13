/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's BIFs (docs/design-runtime.md, "The device NIF"): what a driver calls once per
 * register access or per interrupt, so it pays no NIF entry and exit. Each decodes its terms
 * and makes one call of erx_device.h, which decides and accesses. Anything the table does
 * not allow is badarg, before any access.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "global.h"
#include "bif.h"
#include "big.h"
#include "erl_process.h"
#include "error.h"

#include "erx_device.h"
#include "liberx/backend/api.h"

/* A register named by a BIF's terms, decoded and found in the device's table. */
typedef struct named_register {
	const erx_device_t		*device;
	const erx_device_register_t	*reg;
	erx_device_element_t		element;
} named_register_t;

static const erx_device_t *
decode_device(Eterm dev)
{
	return (is_small(dev) && signed_val(dev) >= 0 ? erx_device_get((uint64_t)signed_val(dev)) : NULL);
}

/* Dev, and Reg: an atom, or {Atom, Index} for an element of an array. */
static bool
decode_register(Eterm dev, Eterm reg, named_register_t *named)
{
	Eterm name = reg;

	named->device = decode_device(dev);
	named->element = (erx_device_element_t){ .indexed = false, .index = 0 };
	if (named->device == NULL)
		return (false);
	if (is_tuple_arity(reg, 2)) {
		const Eterm *const pair = tuple_val(reg);

		if (!is_small(pair[2]) || signed_val(pair[2]) < 0)
			return (false);
		name = pair[1];
		named->element = (erx_device_element_t){ .indexed = true, .index = (uint64_t)signed_val(pair[2]) };
	}
	if (!is_atom(name))
		return (false);
	named->reg = erx_device_register_by_key(named->device, (uintptr_t)name);
	return (named->reg != NULL);
}

static const erx_device_field_t *
decode_field(const named_register_t *named, Eterm field)
{
	return (is_atom(field) ? erx_device_field_by_key(named->device, named->reg, (uintptr_t)field) : NULL);
}

static bool
decode_value(Eterm term, uint64_t *value)
{
	UWord word;

	if (!term_to_UWord(term, &word))
		return (false);
	*value = (uint64_t)word;
	return (true);
}

static Eterm
make_value(Process *process, uint64_t value)
{
	const UWord word = (UWord)value;

	if (IS_USMALL(0, word))
		return (make_small(word));
	return (uword_to_big(word, HAlloc(process, BIG_UWORD_HEAP_SIZE(word))));
}

BIF_RETTYPE
erx_device_read_2(BIF_ALIST_2)
{
	named_register_t named;
	uint64_t value;

	if (!decode_register(BIF_ARG_1, BIF_ARG_2, &named) || !erx_device_read(named.device, named.reg, named.element, &value))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(make_value(BIF_P, value));
}

BIF_RETTYPE
erx_device_write_3(BIF_ALIST_3)
{
	named_register_t named;
	uint64_t value;

	if (!decode_register(BIF_ARG_1, BIF_ARG_2, &named) || !decode_value(BIF_ARG_3, &value) ||
	    !erx_device_write(named.device, named.reg, named.element, value))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(am_ok);
}

BIF_RETTYPE
erx_device_read_field_3(BIF_ALIST_3)
{
	named_register_t named;
	const erx_device_field_t *field;
	uint64_t value;

	if (!decode_register(BIF_ARG_1, BIF_ARG_2, &named))
		BIF_ERROR(BIF_P, BADARG);
	field = decode_field(&named, BIF_ARG_3);
	if (field == NULL || !erx_device_read_field(named.device, named.reg, named.element, field, &value))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(make_value(BIF_P, value));
}

BIF_RETTYPE
erx_device_write_field_4(BIF_ALIST_4)
{
	named_register_t named;
	const erx_device_field_t *field;
	uint64_t value;

	if (!decode_register(BIF_ARG_1, BIF_ARG_2, &named) || !decode_value(BIF_ARG_4, &value))
		BIF_ERROR(BIF_P, BADARG);
	field = decode_field(&named, BIF_ARG_3);
	if (field == NULL || !erx_device_write_field(named.device, named.reg, named.element, field, value))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(am_ok);
}

/* Pure: the field of a word the driver read, so a register that pops on a read, DR, is read once. */
BIF_RETTYPE
erx_device_field_4(BIF_ALIST_4)
{
	named_register_t named;
	const erx_device_field_t *field;
	uint64_t word, value;

	if (!decode_register(BIF_ARG_1, BIF_ARG_2, &named) || !decode_value(BIF_ARG_4, &word))
		BIF_ERROR(BIF_P, BADARG);
	field = decode_field(&named, BIF_ARG_3);
	if (field == NULL || !erx_device_field_of(named.reg, named.element, field, word, &value))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(make_value(BIF_P, value));
}

/* command(Dev, Word): one SD command, the only write of the controller's command register. */
BIF_RETTYPE
erx_device_command_2(BIF_ALIST_2)
{
	const erx_device_t *const device = decode_device(BIF_ARG_1);
	uint64_t word;

	if (device == NULL || !decode_value(BIF_ARG_2, &word) || !erx_device_command(device, word))
		BIF_ERROR(BIF_P, BADARG);
	BIF_RET(am_ok);
}

/*
 * A BIF because a driver makes it once per interrupt. It is a service call on Fiasco, as a
 * NIF's would be, on the normal scheduler the design's deadlock argument allows. A bad
 * device or line is badarg. A refusal of an object the record holds for the boot is not the
 * caller's error, and says so.
 */
BIF_RETTYPE
erx_device_irq_ack_2(BIF_ALIST_2)
{
	const erx_device_t *const device = decode_device(BIF_ARG_1);
	uint64_t irq;

	if (device == NULL || !is_small(BIF_ARG_2) || signed_val(BIF_ARG_2) < 0 ||
	    !erx_device_line_irq(device, (uint64_t)signed_val(BIF_ARG_2), &irq))
		BIF_ERROR(BIF_P, BADARG);
	if (erx_irq_ack(irq) != ERX_OK)
		BIF_ERROR(BIF_P, EXC_INTERNAL_ERROR);
	BIF_RET(am_ok);
}
