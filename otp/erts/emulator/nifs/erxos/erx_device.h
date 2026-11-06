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
#include "erx_device_queue.h"

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

/*
 * Queues (docs/design-runtime.md, "Queues" to "The reset rule"), for a virtio-mmio device of
 * version 2. A queue is state of the device's record for the boot: erx_device_queue's
 * bookkeeping, its rings and its pool of `size` buffers, each in contiguous memory mapped
 * here, whose device addresses nothing outside this file sees. The caller serialises every
 * call below; the register accesses above stay lock-free.
 */
#define ERX_DEVICE_QUEUES_MAX		4u
/* What one erx_device_complete copies before it stops: the entry that crosses it is copied whole. */
#define ERX_DEVICE_COMPLETE_BYTES	65536u

/* One segment of a post: bytes the device reads, or a length of buffer the device writes. */
typedef struct erx_device_piece {
	bool		device_writes;
	const uint8_t	*data;		/* length bytes to copy in when the device reads them */
	uint32_t	length;
} erx_device_piece_t;

/* Where a completion's bytes go: `length` writable bytes the caller made for this tag, never NULL. */
typedef uint8_t	*erx_device_sink_t(void *context, uint64_t tag, uint32_t length);

/*
 * ERX_OK with the queue's name. The device's queue `index`, of `size` entries and as many
 * buffers of `buffer_size` bytes, the size a power of two up to ERX_DEVICE_QUEUE_SIZE_MAX and
 * the pool at most ERX_MEM_CONTIGUOUS_MAX, else ERX_EINVAL. The same queue again is that queue
 * again, posted buffers and all, so a restarted driver finds it, and the same index with
 * another geometry is ERX_EBUSY. A device that is not virtio-mmio version 2 is ERX_ENOTSUP. A
 * new queue is not on the device until erx_device_negotiate installs it. A failure may leave
 * memory made, for the boot.
 */
int	erx_device_queue_create(const erx_device_t *device, uint32_t index, uint32_t size, uint32_t buffer_size,
	    uint32_t *queue);

/*
 * Virtio's initialisation, whole, and the reset rule with it: the NIF resets the device,
 * reads the features it offers, accepts the ones erx_device_queue_features allows of those
 * and of `wanted`, has the device confirm them with FEATURES_OK, installs every queue of the device
 * and sets DRIVER_OK. Installing a queue forgets its chains, returns its buffers to its pool,
 * zeroes its rings and gives the device its size, addresses and ready bit. ERX_OK with the
 * accepted features. ERX_ENOTSUP for a device that is not virtio-mmio version 2, offers no
 * VERSION_1 or refuses FEATURES_OK; ERX_EBUSY for a status that does not read 0 after the
 * reset or a queue the device still has ready after it; ERX_ERANGE for a queue larger than
 * the device offers. Every queue of the device stops being ready at the call's start, and a
 * failure after the reset leaves the device FAILED and every queue's post and complete
 * ERX_ECORRUPT until a later negotiation succeeds.
 */
int	erx_device_negotiate(const erx_device_t *device, uint64_t wanted, uint64_t *accepted);

/*
 * Posts one chain: its pieces, readable before writable, laid end to end in a free buffer of
 * the queue, the readable ones copied in, then the descriptors, the available entry and the
 * doorbell, all or nothing. ERX_EINVAL for no such queue of the device, a count outside
 * 1..ERX_DEVICE_CHAIN_MAX, an empty piece, pieces longer than a buffer or out of order;
 * ERX_EWOULDBLOCK for too few free descriptors; ERX_ECORRUPT for a queue needing a reset.
 */
int	erx_device_post(const erx_device_t *device, uint32_t queue, uint64_t tag, const erx_device_piece_t *pieces,
	    uint32_t count);

/*
 * Completes the entries the device has returned, in order, until ERX_DEVICE_COMPLETE_BYTES are
 * copied: each one's bytes go to what `sink` gives for its tag, and its buffer back to the
 * pool. ERX_OK with how many; ERX_EINVAL for no such queue; ERX_ECORRUPT, with none, for a
 * queue needing a reset, which a device's malformed entry makes it: entries before that one
 * are still completed, and the next call reports it.
 */
int	erx_device_complete(const erx_device_t *device, uint32_t queue, erx_device_sink_t *sink, void *context,
	    uint32_t *completed);

#endif /* ERX_DEVICE_H */
