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
/* The domain's lines: at most every line of every record, each its own. */
#define ERX_DEVICE_LINE_ENTRIES_MAX	(ERX_DEVICE_MAX * ERX_DEVICE_LINES_MAX)

typedef struct erx_device erx_device_t;

/*
 * Where a device's objects come from. A given device's window, lines and memory are objects
 * its domain was given, which it maps and binds; the system domain's root gives itself the
 * devices it holds that are of a kind erx/device_kinds.h lists, so every device that does DMA
 * is given. A physical one's window and lines are made here, which only the root may, and
 * serve the system domain's UARTs, which do no DMA and have no queue; a stand-in is a hosted
 * test's plain memory and software lines.
 */
typedef enum erx_device_form {
	ERX_DEVICE_FORM_PHYSICAL = 0,
	ERX_DEVICE_FORM_GIVEN,
	ERX_DEVICE_FORM_STAND_IN
} erx_device_form_t;

/*
 * What erx_device:open/1 was given. `base` is where the window starts: a physical address,
 * or for a given device an offset in its window object `window`. `lines` are what
 * erx_irq_create takes as a selector, or for a given device its lines' IRQ objects. A given
 * device that does DMA has `memory`, a contiguous object of `memory_size` bytes, a multiple of
 * the page, that every queue of the device is carved from; `memory_size` is 0 for none and for
 * every other form.
 */
typedef struct erx_device_spec {
	const char		*peripheral;
	size_t			peripheral_length;
	erx_device_form_t	form;
	uint64_t		window;
	uint64_t		base;
	uint64_t		size;
	uint32_t		line_count;
	uint64_t		lines[ERX_DEVICE_LINES_MAX];
	bool			shared[ERX_DEVICE_LINES_MAX];	/* the record's mark of each line */
	uint64_t		memory;
	uint64_t		memory_size;
	bool			coherent;	/* the device's DMA is cache-coherent, as the record says */
} erx_device_spec_t;

/* Which element of a register: a plain register takes none, an array one below its count. */
typedef struct erx_device_element {
	bool		indexed;
	uint64_t	index;
} erx_device_element_t;

/*
 * ERX_OK with the device's index. The same spec again is that device again, so a restarted
 * driver finds its record, and the same window with anything else is ERX_EBUSY, as is memory
 * another record holds. Records share what their unit shares
 * (docs/design-shared-devices.md): a window in the pages of a mapped run takes its place in
 * that run's one mapping, and a window whose pages meet a run without being it is
 * ERX_EBUSY; a line another record names is that line's one entry, its IRQ object made
 * once, and a spec that marks it otherwise than the entry, or names a direct line another
 * record names, is ERX_EBUSY. A new run maps its pages, a physical one's made here and a
 * given one's in its window object; a new line's object is made from its selector, or for a
 * given device taken as it is. A given device's memory is mapped whole. A spec that does not
 * fit its peripheral, whose base misaligns one of its registers, that names a line twice, or
 * whose memory is not whole pages of a given device, is ERX_EINVAL. A hosted stand-in,
 * always a new device, is plain memory of the peripheral's size with software objects for
 * lines; elsewhere one is ERX_ENOTSUP. A failure may leave a run or a line made, kept for the
 * boot and taken by the next open that names it. The keys are what the caller interned the
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
 * Issues one SD command (docs/design-runtime.md, "Issuing an SD command"): the one 32-bit write
 * of `word` to an SD host controller's command register, cmdtm, which the NIF owns. False,
 * having touched nothing, for a device whose peripheral is not sdhci and for a word that
 * erx_device_command_allowed refuses: the NIF arms no ADMA2 queue, so no command it issues
 * starts a DMA transfer.
 */
bool	erx_device_command(const erx_device_t *device, uint64_t word);

/*
 * A field's value in a word already read from the register, with no access to the device.
 * A word wider than the register is refused.
 */
bool	erx_device_field_of(const erx_device_register_t *reg, erx_device_element_t element, const erx_device_field_t *field,
	    uint64_t word, uint64_t *value);

/* The IRQ object of the device's line, false for a line it does not have. */
bool	erx_device_line_irq(const erx_device_t *device, uint64_t line, uint64_t *irq);

/*
 * The line's entry, below ERX_DEVICE_LINE_ENTRIES_MAX, which every record naming the line
 * shares, so its one binding is kept by entry; false for a line the device does not have.
 */
bool	erx_device_line_entry(const erx_device_t *device, uint64_t line, uint32_t *entry);

/* Who binds: erx_device:irq_bind/2, a direct line's driver, or irq_bind_owner/2, a shared line's owner. */
typedef enum erx_device_binder {
	ERX_DEVICE_BINDER_DRIVER = 0,
	ERX_DEVICE_BINDER_OWNER
} erx_device_binder_t;

typedef enum erx_device_bind {
	ERX_DEVICE_BIND_OK = 0,
	ERX_DEVICE_BIND_NO_LINE,	/* the device has no such line */
	ERX_DEVICE_BIND_SHARED,		/* a driver's bind of a shared line */
	ERX_DEVICE_BIND_DIRECT,		/* an owner's bind of a direct line */
	ERX_DEVICE_BIND_BUSY		/* the line is bound through another record */
} erx_device_bind_t;

/*
 * Whether `binder` may bind the device's line, which the line's mark decides and no caller
 * says. `through` is the record and `through_line` its line that the line's entry is bound
 * through, `through` NULL when it is unbound: a bind through that record moves the binding,
 * and through any other it is busy, so a line has one binder.
 */
erx_device_bind_t erx_device_bind_check(const erx_device_t *device, uint64_t line, erx_device_binder_t binder,
		    const erx_device_t *through, uint64_t through_line);

/*
 * Queues (docs/design-runtime.md, "Queues" to "The reset rule"), for a virtio-mmio device of
 * version 2. A queue is state of the device's record for the boot: erx_device_queue's
 * bookkeeping, its rings and its pool of `size` buffers, in contiguous memory mapped here,
 * whose device addresses nothing outside this file sees. A given device's queues are carved
 * from its one memory object; a physical device has none. The bookkeeping lives
 * in this record alone and the rings are written whole at the install, so a new record over
 * memory a former record and the device wrote never reads what they left. The caller
 * serialises every call below; the register accesses above stay lock-free.
 */
#define ERX_DEVICE_QUEUES_MAX		4u
/* What one erx_device_complete copies before it stops: the entry that crosses it is copied whole. */
#define ERX_DEVICE_COMPLETE_BYTES	65536u
/* The most entries one erx_device_complete reads and completes; the rest wait for the next call. */
#define ERX_DEVICE_COMPLETE_ENTRIES	32u

/*
 * One segment of a post: bytes the device reads, a length of buffer the device writes, or a
 * region of the record the device reads, which the post writes as the record's region entry
 * (erx_device_region) and for which `data` and `length` are unused.
 */
typedef struct erx_device_piece {
	bool		device_writes;
	bool		names_region;
	uint32_t	region;		/* with names_region, the region's name */
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
 * another geometry is ERX_EBUSY. A device that is neither virtio-mmio version 2 nor GENET is
 * ERX_ENOTSUP. GENET has two queues, its register ring's two directions: 0 receives and 1
 * transmits, each of ERX_GENET_RING_SIZE buffers, any other index or size ERX_EINVAL, and a
 * pool whose device addresses reach past the form's 40 bits ERX_ERANGE. A
 * given device's queue takes the next pages of its memory, and one they do not fit, or a
 * given device with no memory, is ERX_ERANGE with nothing taken. A new queue is not on the
 * device until erx_device_negotiate installs it. A physical device, a UART, has no queue:
 * ERX_ENOTSUP, with nothing made.
 */
int	erx_device_queue_create(const erx_device_t *device, uint32_t index, uint32_t size, uint32_t buffer_size,
	    uint32_t *queue);

/*
 * Regions (docs/design-runtime.md, "Regions"): memory of the record the device reads whenever
 * a request names it, such as a virtio-gpu resource's backing, kept for the boot and never
 * posted.
 *
 * erx_device_region makes the device's region `index`, the driver's own number for it, of
 * `bytes` rounded up to whole pages, and returns ERX_OK with `*region`, the name posts and
 * erx_memdraw use, one name space for every device of the runtime. A given device takes the
 * pages from its memory at the first page no queue or region took (erx_device_carve_region),
 * a stand-in from plain memory; a new region's bytes are zero.
 *
 * The same index with the same bytes is that region again, and with other bytes ERX_EBUSY.
 * Errors: ERX_EINVAL for no bytes; ERX_ERANGE, taking nothing, for one past the
 * memory's end or longer than the region entry states, or a given device with no memory;
 * ERX_ENOTSUP for a physical device and for one that is not coherent, since no transfer names
 * a region, so nothing would clean it before the device reads it; ERX_ELIMIT past
 * ERX_DEVICE_REGIONS_MAX regions.
 */
#define ERX_DEVICE_REGIONS_MAX		4u

int	erx_device_region(const erx_device_t *device, uint32_t index, uint64_t bytes, uint32_t *region);

/*
 * This domain's mapping of a region, for erx_memdraw's images over it: false for a name no
 * region has. A region is never freed, so the mapping stays valid for the boot. Unlike the
 * calls above it takes no serialisation: a region is published whole before its name exists.
 */
bool	erx_device_region_memory(uint32_t region, uint8_t **base, uint64_t *bytes);

/* A domain holds at most one framebuffer row. */
#define ERX_DEVICE_FRAMEBUFFERS_MAX	1u

/*
 * The framebuffer (docs/design-runtime.md, "The framebuffer"): the pages of a framebuffer
 * record's window object, the memory the board's firmware set up and its display hardware
 * scans out, mapped read and write as the object's device memory, kept for the boot.
 *
 * erx_device_framebuffer maps the object `window` from its first page through the page that
 * holds the framebuffer's last byte, `offset` and `bytes` placing the framebuffer in it, and
 * returns ERX_OK with `*framebuffer`, the name erx_memdraw's store takes. The same window,
 * offset and bytes again is that framebuffer again, and anything else ERX_EBUSY, since a
 * domain holds one framebuffer row. Errors: ERX_EINVAL for no bytes, an offset past the first
 * page, or a length that wraps; the kernel's status for a mapping it refuses, the hosted
 * backend's ERX_ENOTSUP among them.
 */
int	erx_device_framebuffer(uint64_t window, uint64_t offset, uint64_t bytes, uint32_t *framebuffer);

/*
 * The framebuffer's bytes as this domain maps them, from its first byte, for erx_memdraw's
 * store: false for a name no framebuffer has. Like a region's, the mapping stays for the boot
 * and is published whole before its name exists, so the call takes no serialisation.
 */
bool	erx_device_framebuffer_memory(uint32_t framebuffer, volatile uint8_t **base, uint64_t *bytes);

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
 *
 * GENET's negotiation is its register ring's reset and install (docs/design-device-dma.md,
 * "Install and reset"): both DMA engines stopped, transmit first, both idle reports read,
 * both rings installed and both engines started, receive first. It accepts no features (0)
 * whatever `wanted` says; ERX_EBUSY, with nothing installed, until both directions report the
 * stop, so the driver calls again; ERX_EINVAL for a record without both its queues.
 */
int	erx_device_negotiate(const erx_device_t *device, uint64_t wanted, uint64_t *accepted);

/*
 * Posts one chain: its pieces, readable before writable, laid end to end in a free buffer of
 * the queue, the readable ones copied in, then the descriptors, the available entry and the
 * doorbell, all or nothing. A piece naming a region is written as the region's entry and read
 * by the device. ERX_EINVAL for no such queue of the device, a count outside
 * 1..ERX_DEVICE_CHAIN_MAX, an empty piece, pieces longer than a buffer or out of order, or a
 * region the device does not have or that a piece names as bytes the device writes;
 * ERX_EWOULDBLOCK for too few free descriptors; ERX_ECORRUPT for a queue needing a reset. On
 * GENET only the transmit queue takes posts, of pieces the device reads, laid end to end in one
 * buffer as one frame; a post on the receive queue, which is standing, is ERX_EINVAL.
 */
int	erx_device_post(const erx_device_t *device, uint32_t queue, uint64_t tag, const erx_device_piece_t *requested,
	    uint32_t count);

/*
 * Completes the entries the device has returned, in order, until ERX_DEVICE_COMPLETE_BYTES are
 * copied or ERX_DEVICE_COMPLETE_ENTRIES are completed: each one's bytes go to what `sink` gives for its tag, and its buffer back to the
 * pool. ERX_OK with how many; ERX_EINVAL for no such queue; ERX_ECORRUPT, with none, for a
 * queue needing a reset, which a device's malformed entry makes it: entries before that one
 * are still completed, and the next call reports it. A GENET transmit completion gives each
 * tag with no bytes; a receive completion gives each frame's bytes with its status flags, the
 * low 16 bits of its descriptor's status, as the tag, and hands the buffers back in the same call.
 */
int	erx_device_complete(const erx_device_t *device, uint32_t queue, erx_device_sink_t *sink, void *context,
	    uint32_t *completed);

#ifdef ERX_DEVICE_STAND_IN
/*
 * A hosted stand-in's device side of a queue, which a test drives as a device would, honest or
 * hostile. Each entry goes into the next slot of the used ring: its id is the head the driver
 * made available next, or any id the test names; its length is any the test names. The used
 * index then moves past them all, so a test makes an index ahead of what is in flight by
 * returning more entries than were posted. ERX_EINVAL for no such queue of a stand-in, a queue
 * not installed, or more entries than the queue has.
 */
typedef struct erx_device_used_entry {
	bool		next;		/* the head the driver made available next, not `id` */
	uint32_t	id;
	uint32_t	length;
} erx_device_used_entry_t;

int	erx_device_stand_in_used(const erx_device_t *device, uint32_t queue, const erx_device_used_entry_t *entries,
	    uint32_t count);

/* One frame a test hands a stand-in GENET to receive. */
typedef struct erx_device_frame {
	const uint8_t	*bytes;
	uint32_t	length;
} erx_device_frame_t;

/*
 * A stand-in GENET's engine, which a test runs as the controller would, through the window
 * and the addresses the descriptors hold, and only while the ring and its DMA are enabled:
 * a stopped controller moves nothing and both calls succeed with none. The test fires the
 * line.
 *
 * erx_device_stand_in_transmitted sends every frame posted since its last run, at most a
 * ring's worth: each descriptor's bytes go to `sink`, tagged with the descriptor's index,
 * and the consumer index moves past them. ERX_EINVAL for a device without that ring
 * installed. ERX_ECORRUPT, sending nothing, for a producer index more than a ring ahead; for a
 * descriptor that is not a whole frame with its CRC (start and end of packet and CRC set),
 * whose length is over the ring's buffer size, or whose address does not reach its bytes
 * in the queue's memory: the frames before it are sent to `sink`, counted in `sent` and
 * moved past, and the controller stops at it.
 *
 * erx_device_stand_in_receive fills free receive buffers with `frames` in order, each after
 * the padding RBUF_CTRL's ALIGN_2B asks for, sets each descriptor's status (the length with
 * the padding, start and end of packet) and moves the producer index past them; `taken` is
 * how many fit, fewer than `count` when the ring is full. ERX_EINVAL for a device without
 * that ring installed, RBUF_CTRL asking for the 64-byte status block, which the stand-in
 * does not lay out, or a frame that with its padding is over the ring's buffer size, before
 * anything is taken. ERX_ECORRUPT for a descriptor whose address does not reach the frame's
 * bytes in the queue's memory, the frames before it taken.
 */
int	erx_device_stand_in_transmitted(const erx_device_t *device, erx_device_sink_t *sink, void *context,
	    uint32_t *sent);
int	erx_device_stand_in_receive(const erx_device_t *device, const erx_device_frame_t *frames, uint32_t count,
	    uint32_t *taken);
#endif

#endif /* ERX_DEVICE_H */
