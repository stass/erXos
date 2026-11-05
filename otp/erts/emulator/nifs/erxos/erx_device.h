/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's effects, in plain C with nothing of ERTS (docs/design-runtime.md, "The device
 * NIF"): the one record each device has for the boot, the mapping of its register window, and
 * the accesses. erx_device_bif.c and erx_device_nif.c turn terms into these calls, and
 * test/guest/native_irq calls them directly.
 *
 * A record is opaque, so these functions alone reach a register window, and each runs the
 * core's check before its access: nothing is left for a caller to remember. A record is
 * written whole, published, and never changes afterwards, so an access takes no lock. A read
 * or a write is one volatile access and never waits.
 */

#ifndef ERX_DEVICE_H
#define ERX_DEVICE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx_device_core.h"

#define ERX_DEVICE_MAX		8u
#define ERX_DEVICE_LINES_MAX	4u

typedef struct erx_device erx_device_t;

/* What erx_device:open/1 was given. `lines` is what erx_irq_create takes as its selector. */
typedef struct erx_device_spec {
	const char	*peripheral;
	size_t		peripheral_length;
	uint64_t	base;
	uint64_t	size;
	bool		stand_in;
	uint32_t	line_count;
	uint64_t	lines[ERX_DEVICE_LINES_MAX];
} erx_device_spec_t;

/* Which element of a register: a plain register takes none, an array one below its count. */
typedef struct erx_device_element {
	bool		indexed;
	uint64_t	index;
} erx_device_element_t;

/*
 * ERX_OK with the device's index. The same spec again is that device again, so a restarted
 * driver finds its record, and the same window with anything else is ERX_EBUSY. A new spec
 * maps the window and makes the lines' objects. A spec that does not fit its peripheral is
 * ERX_EINVAL. A hosted stand-in, always a new device, is plain memory of the peripheral's
 * size with software objects for lines; elsewhere one is ERX_ENOTSUP. A failure may leave a
 * mapping and a line's object made, for the boot. The keys are what the caller interned the
 * table's names as, in the table's order, and may be NULL. The caller serialises opens.
 */
int	erx_device_open(const erx_device_spec_t *spec, const uintptr_t *register_keys, const uintptr_t *field_keys,
	    uint32_t *device);
/* The open device with this index, or NULL. */
const erx_device_t *erx_device_get(uint64_t device);
const erx_device_peripheral_t *erx_device_peripheral(const erx_device_t *device);

/* The register or the field with this key, or NULL. */
const erx_device_register_t *erx_device_register_by_key(const erx_device_t *device, uintptr_t key);
const erx_device_field_t *erx_device_field_by_key(const erx_device_t *device, const erx_device_register_t *reg,
		    uintptr_t key);

/*
 * The accesses. Each is false, having touched nothing, for what the table does not allow: the
 * wrong element, the wrong direction, bits a word may not set, a register holding a device
 * address. The register and the field are the device's own, from the lookups above or from
 * its peripheral.
 */
bool	erx_device_read(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
	    uint64_t *value);
bool	erx_device_write(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
	    uint64_t value);
bool	erx_device_read_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
	    const erx_device_field_t *field, uint64_t *value);
bool	erx_device_write_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
	    const erx_device_field_t *field, uint64_t value);

/*
 * A field's value in a word already read from the register, with no access to the device.
 * A word wider than the register is refused.
 */
bool	erx_device_field_of(const erx_device_register_t *reg, erx_device_element_t element, const erx_device_field_t *field,
	    uint64_t word, uint64_t *value);

/* The IRQ object of the device's line, false for a line it does not have. */
bool	erx_device_line_irq(const erx_device_t *device, uint64_t line, uint64_t *irq);

#endif /* ERX_DEVICE_H */
