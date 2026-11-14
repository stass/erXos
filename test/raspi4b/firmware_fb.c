/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The raspi4b suite's stand-in for the Pi firmware's framebuffer setup
 * (docs/design-platforms.md, "The firmware's framebuffer under QEMU").
 * Test harness only: tools/lib/erx/raspi4b_firmware_fb.rb builds it for one
 * boot of QEMU's raspi4b model, and nothing of erXos links it, packs it or
 * puts it on a card.
 *
 * QEMU's loader starts CPU 0 here instead of in BL31. The stand-in asks the
 * VideoCore for a framebuffer over the mailbox property interface, as the
 * firmware does before it starts BL31, writes the answer into the
 * simple-framebuffer node the harness put in the device tree, and branches
 * to BL31 at address 0 with the registers as reset leaves them.
 *
 * The harness passes, as macros: FB_WIDTH and FB_HEIGHT, the screen it asks
 * for; FB_ORDER, the pixel order (0 BGR, 1 RGB); and the addresses, in the
 * tree as loaded, of the node's cells: FB_REG_CELLS (reg's three cells, the
 * base's high and low words and the size), FB_WIDTH_CELL, FB_HEIGHT_CELL and
 * FB_STRIDE_CELL. The cells hold placeholders the root refuses; an answer
 * that is not the screen asked for leaves them: the root refuses the node,
 * the boot runs with no screen, and the suite's screen check fails.
 *
 * The property interface is the firmware wiki's "Mailbox property
 * interface" and "Mailboxes" pages; the mailbox is the model tree's
 * /soc/mailbox@7e00b880, at 0xfe00b880 through /soc's ranges.
 */

#include <stdint.h>

#define MBOX_BASE		0xfe00b880u
#define MBOX0_READ		(MBOX_BASE + 0x00)
#define MBOX0_STATUS		(MBOX_BASE + 0x18)
#define MBOX1_WRITE		(MBOX_BASE + 0x20)
#define MBOX1_STATUS		(MBOX_BASE + 0x38)
#define MBOX_FULL		0x80000000u
#define MBOX_EMPTY		0x40000000u
#define MBOX_PROPERTY		8u

#define PROP_SUCCESS		0x80000000u
#define TAG_RESPONSE		0x80000000u
#define TAG_SET_PHYSICAL	0x00048003u
#define TAG_SET_VIRTUAL		0x00048004u
#define TAG_SET_DEPTH		0x00048005u
#define TAG_SET_ORDER		0x00048006u
#define TAG_ALLOCATE		0x00040001u
#define TAG_GET_PITCH		0x00040008u

#define FB_DEPTH		32u
#define FB_ALIGN		4096u

/*
 * One request of six tags; the firmware processes the frame buffer tags
 * as one operation, the Get tags (allocate, pitch) after the Set tags. Each
 * tag is its id, its value buffer's size, its request/response code and
 * its value buffer; the indexes below name the words of the answer.
 */
enum {
	A_CODE = 1,
	A_PHYSICAL = 2, A_PHYSICAL_W = 5, A_PHYSICAL_H = 6,
	A_VIRTUAL = 7, A_VIRTUAL_W = 10, A_VIRTUAL_H = 11,
	A_DEPTH = 12, A_DEPTH_V = 15,
	A_ORDER = 16, A_ORDER_V = 19,
	A_ALLOCATE = 20, A_BASE = 23, A_SIZE = 24,
	A_PITCH = 25, A_PITCH_V = 28,
	A_END = 29,
	A_WORDS = 32		/* the buffer padded to 16 bytes */
};

static volatile uint32_t request[A_WORDS] __attribute__((aligned(16))) = {
	[0] = sizeof(request), [A_CODE] = 0,
	[A_PHYSICAL] = TAG_SET_PHYSICAL, 8, 0, FB_WIDTH, FB_HEIGHT,
	[A_VIRTUAL] = TAG_SET_VIRTUAL, 8, 0, FB_WIDTH, FB_HEIGHT,
	[A_DEPTH] = TAG_SET_DEPTH, 4, 0, FB_DEPTH,
	[A_ORDER] = TAG_SET_ORDER, 4, 0, FB_ORDER,
	[A_ALLOCATE] = TAG_ALLOCATE, 8, 0, FB_ALIGN, 0,
	[A_PITCH] = TAG_GET_PITCH, 4, 0, 0,
	[A_END] = 0
};

static const unsigned tags[] = { A_PHYSICAL, A_VIRTUAL, A_DEPTH, A_ORDER, A_ALLOCATE, A_PITCH };

void	firmware_fb(void);

/*
 * The entry, first in .text where the ELF's entry points: a stack below
 * this image, the request, then BL31 with x0 to x3 zero, as at reset.
 */
__asm__(
    ".text\n"
    ".globl firmware_fb_entry\n"
    "firmware_fb_entry:\n"
    "	adr	x0, firmware_fb_entry\n"
    "	mov	sp, x0\n"
    "	bl	firmware_fb\n"
    "	mov	x0, #0\n"
    "	mov	x1, #0\n"
    "	mov	x2, #0\n"
    "	mov	x3, #0\n"
    "	mov	x30, #0\n"
    "	br	x30\n");

static uint32_t
mmio_read(uint32_t address)
{
	return (*(volatile uint32_t *)(uintptr_t)address);
}

static void
mmio_write(uint32_t address, uint32_t value)
{
	*(volatile uint32_t *)(uintptr_t)address = value;
}

/* A device tree cell is big-endian; the cells are 4-byte aligned. */
static void
cell_put(uint32_t address, uint32_t value)
{
	mmio_write(address, __builtin_bswap32(value));
}

/* Sends the request on the property channel and waits for its answer. */
static void
mailbox_call(void)
{
	uint32_t message = (uint32_t)(uintptr_t)request | MBOX_PROPERTY;

	while (mmio_read(MBOX1_STATUS) & MBOX_FULL)
		continue;
	mmio_write(MBOX1_WRITE, message);
	for (;;) {
		while (mmio_read(MBOX0_STATUS) & MBOX_EMPTY)
			continue;
		if (mmio_read(MBOX0_READ) == message)
			return;
	}
}

/* Whether the firmware answered every tag with the screen asked for. */
static int
answered(void)
{
	unsigned i;

	if (request[A_CODE] != PROP_SUCCESS)
		return (0);
	for (i = 0; i < sizeof(tags) / sizeof(tags[0]); i++)
		if ((request[tags[i] + 2] & TAG_RESPONSE) == 0)
			return (0);
	return (request[A_PHYSICAL_W] == FB_WIDTH && request[A_PHYSICAL_H] == FB_HEIGHT &&
	    request[A_VIRTUAL_W] == FB_WIDTH && request[A_VIRTUAL_H] == FB_HEIGHT &&
	    request[A_DEPTH_V] == FB_DEPTH && request[A_ORDER_V] == FB_ORDER &&
	    request[A_BASE] != 0 && request[A_SIZE] != 0 && request[A_PITCH_V] != 0);
}

void
firmware_fb(void)
{
	mailbox_call();
	if (!answered())
		return;
	cell_put(FB_REG_CELLS, 0);
	cell_put(FB_REG_CELLS + 4, request[A_BASE]);
	cell_put(FB_REG_CELLS + 8, request[A_SIZE]);
	cell_put(FB_WIDTH_CELL, request[A_VIRTUAL_W]);
	cell_put(FB_HEIGHT_CELL, request[A_VIRTUAL_H]);
	cell_put(FB_STRIDE_CELL, request[A_PITCH_V]);
}
