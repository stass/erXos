/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Interrupts through the readiness interface (docs/design-fiasco.md, "Interrupts and
 * readiness", "Verification"), as the root task; tools/lib/erx/native_irq.rb judges the
 * transcript and types the characters. The first thread rings the software object when
 * the executor is seen parked, a handshake that needs no sleep; the executor runs on
 * another CPU when there is one, so a wake crosses CPUs. Last, the root passes a device's
 * objects to a holder task, test/guest/native_irq/program.c, which binds the line to its
 * own group and takes the third character.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/handles.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/root_layout.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/backend/runtime_entry.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"
#include "test/guest/native_irq/holder.h"

/* QEMU virt's PL011: its registers, and its receive line, SPI 1. */
#define UART_PHYS	UINT64_C(0x9000000)
#define UART_LINE	33u
/*
 * QEMU virt's PL031, another device of one page (config/platforms/qemu-virt.json), and
 * the offset of the first identification word of either, which reads the same each time
 * and differs between the two.
 */
#define RTC_PHYS	UINT64_C(0x9010000)
#define ID_OFFSET	0xfe0u

/* QEMU virt's MSI frame, as config/platforms/qemu-virt.json names it, and its doorbell's offset. */
#define MSI_FRAME_BASE	UINT64_C(0x08020000)
#define MSI_FIRST	80u
#define MSI_COUNT	64u
#define MSI_DOORBELL	UINT64_C(0x40)

#define LABEL_UART	UINT64_C(0x55a0)
#define LABEL_SOFT	UINT64_C(0x55b1)
#define LABEL_OTHER	UINT64_C(0x55c2)
#define LABEL_MOVED	UINT64_C(0x55d3)

#define NS_PER_MS	UINT64_C(1000000)
/* More entries than the root's free list holds here, so a freed entry would come up among them. */
#define DESTROYED_DUPS	1024u
/* How long a park waits before the case says the wake was lost. */
#define PATIENCE_NS	(UINT64_C(30000) * NS_PER_MS)
#define TIMED_PARK_NS	(UINT64_C(20) * NS_PER_MS)
/* How long a pending line is watched after its bind for a delivery that must not come. */
#define PENDING_NS	(UINT64_C(200) * NS_PER_MS)
#define RING_ROUNDS	1000u
/* Creates and destroys of one register window: more than the device window ever held pages for at once. */
#define WINDOW_ROUNDS	5000u
#define REPEATS		3u
/*
 * How long a wait for another thread sleeps between looks. A wait blocks and never yields
 * in a loop (docs/design-fiasco.md, "A wait blocks"): a yield reaches only threads of the
 * root's own level, so a looping root would keep the holder task, at the app level, off a
 * one-CPU machine.
 */
#define POLL_US		UINT64_C(100)
#define STACK_BYTES	16384u
#define WALL_NS		(UINT64_C(1800000000) * UINT64_C(1000000000))
#define HOLDER_PROGRAM	"boot/native-irq-holder"

void erx_fiasco_root_main(void);

static _Alignas(16) uint8_t executor_stack[STACK_BYTES];
static uint64_t irq_uart, irq_soft, irq_other, root_group;
static uint32_t holder_entry;
static const erx_device_t *uart;
/* The executor's ask of the first thread: ring the software object once it is parked. */
static _Atomic uint32_t ring_wanted;
static _Atomic uint32_t cases_done;

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

static _Noreturn void
fail(const char *text)
{
	say(text);
	erx_fiasco_end(ERX_FIASCO_END_ASKED_OFF, NULL);
}

/* "erx: irq: <what> 0x<value> 0x<other>\n", all in one write so no line splits. */
static void
report(const char *what, uint64_t value, uint64_t other)
{
	char line[128];
	const uint64_t values[2] = { value, other };
	size_t at = 0;

	for (const char *from = what; *from != '\0'; from++)
		line[at++] = *from;
	for (size_t index = 0; index < 2; index++) {
		line[at++] = ' ';
		line[at++] = '0';
		line[at++] = 'x';
		for (int shift = 60; shift >= 0; shift -= 4)
			line[at++] = "0123456789abcdef"[(values[index] >> shift) & 0xf];
	}
	line[at++] = '\n';
	erx_fiasco_console_write(line, at);
}

/*
 * The holder's status, in decimal as program.c numbers its steps, in the line that fails the
 * suite; a fault's status is negative.
 */
static _Noreturn void
fail_status(int64_t status)
{
	static const char head[] = "erx: irq: the holder's status ", tail[] = " FAILED\n";
	char line[sizeof(head) + 20 + sizeof(tail)], digits[20];
	uint64_t magnitude = status < 0 ? (uint64_t)0 - (uint64_t)status : (uint64_t)status;
	size_t at = 0, used = 0;

	for (size_t index = 0; index < sizeof(head) - 1; index++)
		line[at++] = head[index];
	if (status < 0)
		line[at++] = '-';
	do {
		digits[used++] = (char)('0' + magnitude % 10);
		magnitude /= 10;
	} while (magnitude != 0);
	while (used > 0)
		line[at++] = digits[--used];
	for (size_t index = 0; index < sizeof(tail); index++)
		line[at++] = tail[index];
	fail(line);
}

static const erx_device_register_t *
uart_register(const char *name)
{
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral(uart);
	const uint32_t index = erx_device_register_named(peripheral, name);

	if (index == peripheral->register_count)
		fail("erx: irq: the table lacks a register FAILED\n");
	return (&peripheral->registers[index]);
}

static const erx_device_field_t *
uart_field(const erx_device_register_t *reg, const char *name)
{
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral(uart);
	const uint32_t index = erx_device_field_named(peripheral, reg, name);

	if (index == reg->field_count)
		fail("erx: irq: the table lacks a field FAILED\n");
	return (&peripheral->fields[reg->first_field + index]);
}

static uint64_t
uart_read_field(const char *reg_name, const char *field_name)
{
	const erx_device_register_t *const reg = uart_register(reg_name);
	const erx_device_element_t element = { .indexed = false };
	uint64_t value;

	if (!erx_device_read_field(uart, reg, element, uart_field(reg, field_name), &value))
		fail("erx: irq: the table refused a field's read FAILED\n");
	return (value);
}

static void
uart_set_field(const char *reg_name, const char *field_name)
{
	const erx_device_register_t *const reg = uart_register(reg_name);
	const erx_device_element_t element = { .indexed = false };

	if (!erx_device_write_field(uart, reg, element, uart_field(reg, field_name), 1))
		fail("erx: irq: the table refused a field's update FAILED\n");
}

static uint32_t
own_slot(void)
{
	return (erx_fiasco_thread_self()->executor_slot);
}

static uint64_t
group_epoch(void)
{
	return (atomic_load_explicit(&erx_fiasco_group_status()->epoch, memory_order_acquire));
}

static uint64_t
slot_epoch(void)
{
	return (atomic_load_explicit(&erx_fiasco_group_status()->exec[own_slot()].epoch, memory_order_acquire));
}

static uint64_t
mr_label(uint32_t index)
{
	return (atomic_load_explicit(&erx_utcb_self()->mr[index], memory_order_relaxed));
}

/* The runtime's loop: epochs, then the empty check, then the park. Returns the one label taken. */
static uint64_t
wait_label(bool ring_parked)
{
	for (;;) {
		const uint64_t group = group_epoch(), slot = slot_epoch();
		const int taken = erx_group_take_ready(ERX_MSG_WORDS);

		if (taken < 0)
			fail("erx: irq: take_ready refused an executor FAILED\n");
		if (taken == 1)
			return (mr_label(0));
		if (taken > 1)
			fail("erx: irq: more labels than objects fired FAILED\n");
		if (ring_parked)
			atomic_store_explicit(&ring_wanted, 1, memory_order_release);
		if (erx_park(group, slot, erx_fiasco_clock_ns() + PATIENCE_NS) != ERX_OK)
			fail("erx: irq: a lost wake: the park reached its deadline FAILED\n");
	}
}

static void
expect_empty(void)
{
	if (erx_group_take_ready(ERX_MSG_WORDS) != 0)
		fail("erx: irq: a label twice FAILED\n");
}

static void
trigger(uint64_t irq)
{
	if (erx_irq_trigger(irq) != ERX_OK)
		fail("erx: irq: a trigger was refused FAILED\n");
}

/* Fires an object and waits for the dispatcher to run its trigger, seen as the epoch moving. */
static void
trigger_and_see(uint64_t irq)
{
	const uint64_t before = group_epoch();

	trigger(irq);
	while (group_epoch() == before)
		erx_fiasco_test_ipc_sleep_us(POLL_US);
}

static void
case_parked_wake(void)
{
	if (wait_label(true) != LABEL_SOFT)
		fail("erx: irq: a parked executor woke to the wrong label FAILED\n");
	expect_empty();
	say("erx: irq: a parked executor woke to its label\n");
}

/*
 * A trigger between the empty check and the park: the epochs were read before it, so
 * the park returns at once. The deadline is the patience: a park that slept here
 * would have nothing left to wake it.
 */
static void
case_trigger_before_park(void)
{
	const uint64_t group = group_epoch(), slot = slot_epoch();

	if (erx_group_take_ready(ERX_MSG_WORDS) != 0)
		fail("erx: irq: the ready list was not empty FAILED\n");
	trigger_and_see(irq_soft);
	if (erx_park(group, slot, erx_fiasco_clock_ns() + PATIENCE_NS) != ERX_OK)
		fail("erx: irq: a trigger before the park was lost FAILED\n");
	if (atomic_load_explicit(&erx_fiasco_group_status()->exec[own_slot()].state, memory_order_relaxed) ==
	    ERX_EXEC_STATE_PARKED)
		fail("erx: irq: the slot stayed parked FAILED\n");
	if (wait_label(false) != LABEL_SOFT)
		fail("erx: irq: the wrong label after the park FAILED\n");
	expect_empty();
	say("erx: irq: a trigger before the park returned at once\n");
}

/* Every fire seen, the object taken once; two objects in the order they fired. */
static void
case_once_and_order(void)
{
	const uint64_t before = group_epoch();

	for (uint32_t repeat = 0; repeat < REPEATS; repeat++)
		trigger_and_see(irq_soft);
	if (group_epoch() != before + REPEATS)
		fail("erx: irq: a trigger did not advance the epoch FAILED\n");
	if (atomic_load_explicit(&erx_fiasco_group_status()->ready, memory_order_relaxed) != 1)
		fail("erx: irq: the status page's ready disagrees FAILED\n");
	if (erx_group_take_ready(ERX_MSG_WORDS) != 1 || mr_label(0) != LABEL_SOFT)
		fail("erx: irq: repeated triggers did not give one label FAILED\n");
	expect_empty();
	trigger_and_see(irq_other);
	trigger_and_see(irq_soft);
	if (erx_group_take_ready(1) != 1 || mr_label(0) != LABEL_OTHER)
		fail("erx: irq: the oldest object did not come first FAILED\n");
	if (erx_group_take_ready(1) != 1 || mr_label(0) != LABEL_SOFT)
		fail("erx: irq: the second object did not follow FAILED\n");
	expect_empty();
	say("erx: irq: each label once, oldest first\n");
}

/*
 * Binding again moves an object's label, and ERX_CAP_SELF names the caller's own group.
 * Unbinding twice is the same as once. A fire while unbound is owed to the next bind, and
 * reaches that bind's label once.
 */
static void
case_move_and_unbind(void)
{
	if (erx_irq_bind(irq_other, ERX_CAP_SELF, LABEL_MOVED) != ERX_OK)
		fail("erx: irq: a move to ERX_CAP_SELF was refused FAILED\n");
	trigger_and_see(irq_other);
	if (wait_label(false) != LABEL_MOVED)
		fail("erx: irq: the moved object kept its old label FAILED\n");
	expect_empty();
	if (erx_irq_bind(irq_other, ERX_CAP_NULL, 0) != ERX_OK || erx_irq_bind(irq_other, ERX_CAP_NULL, 0) != ERX_OK)
		fail("erx: irq: an unbind was refused FAILED\n");
	trigger(irq_other);
	trigger_and_see(irq_soft);
	if (wait_label(false) != LABEL_SOFT)
		fail("erx: irq: an unbound object delivered FAILED\n");
	expect_empty();
	if (erx_irq_bind(irq_other, ERX_CAP_SELF, LABEL_OTHER) != ERX_OK)
		fail("erx: irq: a bind after an unbind was refused FAILED\n");
	if (wait_label(false) != LABEL_OTHER)
		fail("erx: irq: the owed fire did not reach the new bind FAILED\n");
	expect_empty();
	say("erx: irq: a bind moves, an unbind stops, a fire stays owed\n");
}

static void
case_timed_park(void)
{
	const uint64_t group = group_epoch(), slot = slot_epoch();
	const uint64_t deadline = erx_time_monotonic_ns() + TIMED_PARK_NS;
	const int status = erx_park(group, slot, deadline);

	if (status != ERX_ETIMEDOUT)
		fail("erx: irq: a park with no wake did not time out FAILED\n");
	if (erx_time_monotonic_ns() < deadline)
		fail("erx: irq: a timed park ended before its deadline FAILED\n");
	say("erx: irq: a timed park ended at its deadline\n");
}

static void
case_rounds(void)
{
	for (uint32_t round = 0; round < RING_ROUNDS; round++) {
		if (wait_label(true) != LABEL_SOFT)
			fail("erx: irq: a round took the wrong label FAILED\n");
		expect_empty();
	}
	say("erx: irq: rounds of ring and park kept every wake\n");
}

/* One character: its label, its byte, then the ack. The byte goes first, since the line is level. */
static void
uart_take(void)
{
	uint64_t label;
	uint64_t byte;

	label = wait_label(false);
	if (uart_read_field("fr", "rxfe") != 0)
		fail("erx: irq: the line fired with no byte waiting FAILED\n");
	byte = uart_read_field("dr", "data");
	if (uart_read_field("fr", "rxfe") == 0)
		fail("erx: irq: more than one byte waited FAILED\n");
	report("erx: irq: uart label byte", label, byte);
	if (erx_irq_ack(irq_uart) != ERX_OK)
		fail("erx: irq: the service refused an ack FAILED\n");
}

static void
case_uart(const char *prompt)
{
	say(prompt);
	uart_take();
}

/*
 * A restarted driver's path on a real line: an unbind masks it, and a bind leaves it
 * masked until the driver's first ack (docs/design-kernel.md, "IRQ objects"). The
 * harness's character arrives while the line is unbound, so the level line is pending
 * at the bind; a park from before the bind sees no label, and the ack lets it deliver.
 */
static void
case_pending_bind(void)
{
	uint64_t group, slot;

	if (erx_irq_bind(irq_uart, ERX_CAP_NULL, 0) != ERX_OK)
		fail("erx: irq: the line was not unbound FAILED\n");
	say("erx: irq: type a character\n");
	while (uart_read_field("fr", "rxfe") != 0)
		erx_fiasco_test_ipc_sleep_us(POLL_US);
	group = group_epoch();
	slot = slot_epoch();
	if (erx_irq_bind(irq_uart, ERX_CAP_SELF, LABEL_UART) != ERX_OK)
		fail("erx: irq: the line was not bound again FAILED\n");
	if (erx_park(group, slot, erx_time_monotonic_ns() + PENDING_NS) != ERX_ETIMEDOUT ||
	    erx_group_take_ready(ERX_MSG_WORDS) != 0)
		fail("erx: irq: a pending line delivered at its bind, before its first ack FAILED\n");
	say("erx: irq: a pending line stayed masked until its first ack\n");
	if (erx_irq_ack(irq_uart) != ERX_OK)
		fail("erx: irq: the service refused an ack FAILED\n");
	uart_take();
}

/*
 * The direct doorbell (docs/design-fiasco.md, "The release's cases"): a ring and its wake
 * make no request to the root, so the service's count of messages is unchanged across
 * them. Number 0 names no entry, whatever the generation bits hold, so its ring and its
 * ack are ERX_ESTALE.
 */
static void
case_direct_doorbell(void)
{
	uint64_t received;

	if (erx_irq_trigger(ERX_CAP_NULL) != ERX_ESTALE || erx_irq_ack(UINT64_C(1) << 40) != ERX_ESTALE)
		fail("erx: irq: a handle of number 0 reached a slot FAILED\n");
	expect_empty();
	received = erx_fiasco_test_received();
	trigger(irq_soft);
	if (wait_label(false) != LABEL_SOFT)
		fail("erx: irq: a direct ring woke to the wrong label FAILED\n");
	if (erx_fiasco_test_received() != received)
		fail("erx: irq: a ring or its wake made a request to the root FAILED\n");
	say("erx: irq: a ring and its wake made no request to the root\n");
}

/* A copy rings the same object; once closed, its slot is empty, so it rings and acks nothing. */
static void
case_closed_handle(void)
{
	uint64_t copy;

	if (erx_cap_dup(irq_soft, &copy) != ERX_OK)
		fail("erx: irq: the doorbell was not duplicated FAILED\n");
	trigger(copy);
	if (wait_label(false) != LABEL_SOFT)
		fail("erx: irq: a copy rang another object FAILED\n");
	if (erx_cap_close((erx_cap_t){ .raw = copy }) != ERX_OK)
		fail("erx: irq: the copy was not closed FAILED\n");
	if (erx_irq_trigger(copy) != ERX_ESTALE || erx_irq_ack(copy) != ERX_ESTALE)
		fail("erx: irq: a ring after close reached the object FAILED\n");
	expect_empty();
	say("erx: irq: a closed handle rings nothing\n");
}

/*
 * The destroyed handle (docs/design-fiasco.md, "The release's cases"): after the creator's
 * destroy, a holder's ring and its service call both answer ERX_ESTALE. Its entry stays
 * taken until its own close, so no new entry takes its number and its slot stays empty
 * however many entries are made after.
 */
static void
case_destroyed_handle(void)
{
	static uint64_t dups[DESTROYED_DUPS];
	uint64_t made, copy, other;

	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &made, NULL) != ERX_OK || erx_cap_dup(made, &copy) != ERX_OK)
		fail("erx: irq: the doorbell and its copy were not made FAILED\n");
	if (erx_object_destroy(made) != ERX_OK)
		fail("erx: irq: the doorbell was not destroyed FAILED\n");
	if (erx_irq_trigger(copy) != ERX_ESTALE || erx_irq_bind(copy, ERX_CAP_SELF, LABEL_OTHER) != ERX_ESTALE)
		fail("erx: irq: a destroyed doorbell's holder reached it FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &other, NULL) != ERX_OK)
		fail("erx: irq: no doorbell after the destroy FAILED\n");
	for (uint32_t at = 0; at < DESTROYED_DUPS; at++) {
		if (erx_cap_dup(other, &dups[at]) != ERX_OK)
			fail("erx: irq: the new doorbell was not duplicated FAILED\n");
		if (ERX_BACKEND_HANDLE_NUMBER(dups[at]) == ERX_BACKEND_HANDLE_NUMBER(copy))
			fail("erx: irq: a destroyed doorbell's entry was taken again FAILED\n");
	}
	if (erx_irq_trigger(copy) != ERX_ESTALE)
		fail("erx: irq: a destroyed doorbell's slot holds an object FAILED\n");
	for (uint32_t at = 0; at < DESTROYED_DUPS; at++)
		if (erx_cap_close((erx_cap_t){ .raw = dups[at] }) != ERX_OK)
			fail("erx: irq: a copy of the new doorbell was not closed FAILED\n");
	if (erx_object_destroy(other) != ERX_OK || erx_cap_close((erx_cap_t){ .raw = other }) != ERX_OK ||
	    erx_cap_close((erx_cap_t){ .raw = made }) != ERX_OK || erx_cap_close((erx_cap_t){ .raw = copy }) != ERX_OK)
		fail("erx: irq: the destroyed doorbells' entries were not closed FAILED\n");
	say("erx: irq: a destroyed handle answers stale\n");
}

/*
 * Fiasco's object space under the release's configuration (docs/design-fiasco.md, "Handles"):
 * a cap_limit whose window passes the object space's last slot is ERX_EINVAL, the largest
 * that fits is what erx_space_cap_limit_max answers and makes a space, and the backend's
 * probe places a capability at that last slot and none past it.
 */
static void
check_object_space(void)
{
	uint64_t gate, space;
	int64_t ignored;
	const char *reason;

	if (erx_space_cap_limit_max() != ERX_FIASCO_CAP_LIMIT_MAX)
		fail("erx: irq: the largest cap_limit answered is not the object space's FAILED\n");
	if (erx_space_create(0, ERX_CAP_SELF, 0, 0, 0, erx_space_cap_limit_max() + 1, &space) != ERX_EINVAL)
		fail("erx: irq: a window past the object space was admitted FAILED\n");
	if (erx_gate_create(0, &gate) != ERX_OK ||
	    erx_space_create(0, ERX_CAP_SELF, gate, 0, 0, erx_space_cap_limit_max(), &space) != ERX_OK)
		fail("erx: irq: the largest window that fits was refused FAILED\n");
	(void)erx_space_stop(space, 0);
	(void)erx_fiasco_task_join(space, &ignored);
	if (erx_object_destroy(gate) != ERX_OK || erx_cap_close((erx_cap_t){ .raw = gate }) != ERX_OK)
		fail("erx: irq: the space's fault gate did not go FAILED\n");
	reason = erx_fiasco_test_object_space_probe(irq_soft);
	if (reason != NULL)
		fail(reason);
	say("erx: irq: the object space ends at slot 65535\n");
}

/* One item of the caller's UTCB for erx_cap_pass: a copy of cap with mask's rights. */
static void
item_put(uint32_t item, uint64_t cap, uint32_t mask)
{
	uint64_t desc = 0;

	(void)erx_msg_item_desc_rights_set(&desc, mask);
	(void)erx_utcb_mr_store(erx_utcb_self(), 2 * item, desc);
	(void)erx_utcb_mr_store(erx_utcb_self(), 2 * item + 1, cap);
}

/*
 * Passes the holder's handles into task, in holder.h's order and as many at a time as a
 * pass takes, and gives their values in task's table packed as the holder's argument.
 */
static uint64_t
holder_pass(uint64_t task, const uint64_t objects[HOLDER_HANDLES], const uint32_t masks[HOLDER_HANDLES])
{
	uint64_t argument = 0;

	for (uint32_t first = 0; first < HOLDER_HANDLES; first += ERX_MSG_CAPS) {
		const uint32_t count = HOLDER_HANDLES - first < ERX_MSG_CAPS ? HOLDER_HANDLES - first : ERX_MSG_CAPS;

		for (uint32_t item = 0; item < count; item++)
			item_put(item, objects[first + item], masks[first + item]);
		if (erx_cap_pass(ERX_CAP_SELF, task, count) != ERX_OK)
			fail("erx: irq: the holder's handles were not passed FAILED\n");
		for (uint32_t item = 0; item < count; item++) {
			uint64_t value = ERX_CAP_NULL;

			(void)erx_utcb_mr_load(erx_utcb_self(), 2 * item + 1, &value);
			if (value == ERX_CAP_NULL || value > HOLDER_HANDLE_MASK)
				fail("erx: irq: a holder's handle does not fit its argument FAILED\n");
			argument |= value << ((first + item) * HOLDER_HANDLE_BITS);
		}
	}
	return (argument);
}

/*
 * The holder's objects, made in the root as the domain library makes a device's for its
 * holder: the root gives up its own object of the UART's line, which a line has one of,
 * and makes it again, then a register window over the UART and a contiguous run. The
 * run's first word holds the DMA address the root got for it, for the holder to compare.
 */
static void
holder_objects_make(uint64_t objects[HOLDER_HANDLES])
{
	uint64_t addr, dma;

	if (erx_object_destroy(irq_uart) != ERX_OK)
		fail("erx: irq: the root's line object was not destroyed FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_LINE, UART_LINE, &objects[HOLDER_LINE], NULL) != ERX_OK)
		fail("erx: irq: the line's object was not made again FAILED\n");
	if (erx_mem_create_physical(0, 0, UART_PHYS, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, &objects[HOLDER_WINDOW]) != ERX_OK)
		fail("erx: irq: the holder's window was not made FAILED\n");
	if (erx_mem_create_contiguous(0, 0, HOLDER_RUN_BYTES, 0, &objects[HOLDER_RUN]) != ERX_OK)
		fail("erx: irq: the holder's run was not made FAILED\n");
	if (erx_vm_reserve(ERX_CAP_SELF, 0, HOLDER_RUN_BYTES, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, HOLDER_RUN_BYTES, objects[HOLDER_RUN], 0, ERX_PROT_RW) != ERX_OK)
		fail("erx: irq: the holder's run was not mapped FAILED\n");
	if (erx_mem_dma_addr(objects[HOLDER_RUN], 0, &dma) != ERX_OK)
		fail("erx: irq: the run had no DMA address FAILED\n");
	*(volatile uint64_t *)(uintptr_t)addr = dma;
	objects[HOLDER_ROOT_GROUP] = root_group;
	objects[HOLDER_ROOT_SOFT] = irq_soft;
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &objects[HOLDER_INSPECT], NULL) != ERX_OK)
		fail("erx: irq: the holder's inspection-only object was not made FAILED\n");
}

/*
 * A move is a copy and then the close of the caller's entry, so the moved doorbell's slot
 * in the caller empties as at any close, and a ring through the old value reaches nothing.
 */
static void
moved_check(uint64_t task)
{
	uint64_t copy, desc = 0;

	if (erx_cap_dup(irq_soft, &copy) != ERX_OK)
		fail("erx: irq: the doorbell to move was not duplicated FAILED\n");
	(void)erx_msg_item_desc_rights_set(&desc, ERX_HR_TRIGGER);
	(void)erx_msg_item_desc_move_set(&desc, 1);
	(void)erx_utcb_mr_store(erx_utcb_self(), 0, desc);
	(void)erx_utcb_mr_store(erx_utcb_self(), 1, copy);
	if (erx_cap_pass(ERX_CAP_SELF, task, 1) != ERX_OK)
		fail("erx: irq: the doorbell was not moved FAILED\n");
	if (erx_irq_trigger(copy) != ERX_ESTALE)
		fail("erx: irq: a ring after a move reached the object FAILED\n");
}

/*
 * Makes the holder task, passes it the objects and starts its first thread in a new group,
 * which makes the holder that group's home, then waits for its end and gives its status.
 * The masks are the rights the target design gives each handle, which each new entry records;
 * the IRQ entries holding ERX_HR_TRIGGER or ERX_HR_ACK get a capability, and the
 * inspection-only one gets none (docs/design-fiasco.md, "Handles").
 */
static int64_t
holder_run(const uint64_t objects[HOLDER_HANDLES])
{
	static const uint32_t masks[HOLDER_HANDLES] = {
		[HOLDER_LINE] = ERX_HR_BIND | ERX_HR_ACK, [HOLDER_WINDOW] = ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP,
		[HOLDER_RUN] = ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP | ERX_HR_PHYS, [HOLDER_ROOT_GROUP] = ERX_HR_ATTACH,
		[HOLDER_ROOT_SOFT] = ERX_HR_TRIGGER, [HOLDER_INSPECT] = ERX_HR_INSPECT | ERX_HR_DUP };
	uint64_t group, task, pc, thread, argument;
	int64_t status = INT64_MIN;

	if (erx_group_create(0, 0, &group) != ERX_OK)
		fail("erx: irq: no group for the holder FAILED\n");
	if (erx_fiasco_launch_make(holder_entry, 0, &task, &pc) != ERX_OK)
		fail("erx: irq: no holder task FAILED\n");
	argument = holder_pass(task, objects, masks);
	/* Before the registers, which erx_thread_create takes from the same UTCB words. */
	moved_check(task);
	erx_fiasco_launch_set_registers(pc, argument);
	if (erx_thread_create(0, task, group, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK || erx_thread_start(thread) != ERX_OK)
		fail("erx: irq: the holder's first thread did not start FAILED\n");
	if (erx_fiasco_task_join(task, &status) != ERX_OK)
		fail("erx: irq: the holder was not joined FAILED\n");
	/* The group went with its home, so the handle is stale; its close only frees the entry. */
	(void)erx_cap_close((erx_cap_t){ .raw = group });
	return (status);
}

/*
 * A device another domain holds (docs/design-fiasco.md, "Device records"): the root makes
 * a device's objects and passes them, with the root's own group and a software object bound
 * there, to a holder task (program.c), whose status says how far it got. The byte the line
 * fired for is still waiting, and the root reads it through its own window, so the harness
 * sees the holder's label and the byte as for the root's characters. The objects stay the
 * root's, and its destroy of each is the last check.
 */
static void
case_holder(void)
{
	uint64_t objects[HOLDER_HANDLES], byte;
	int64_t status;

	holder_objects_make(objects);
	status = holder_run(objects);
	if (status != 0)
		fail_status(status);
	if (uart_read_field("fr", "rxfe") != 0)
		fail("erx: irq: the holder's line fired with no byte waiting FAILED\n");
	byte = uart_read_field("dr", "data");
	report("erx: irq: holder label byte", HOLDER_LABEL, byte);
	if (erx_object_destroy(objects[HOLDER_LINE]) != ERX_OK || erx_object_destroy(objects[HOLDER_WINDOW]) != ERX_OK ||
	    erx_object_destroy(objects[HOLDER_RUN]) != ERX_OK)
		fail("erx: irq: the holder's objects were not the root's FAILED\n");
}

static void
executor_main(uint64_t unused)
{
	(void)unused;
	case_parked_wake();
	case_trigger_before_park();
	case_once_and_order();
	case_move_and_unbind();
	case_timed_park();
	case_rounds();
	case_direct_doorbell();
	case_closed_handle();
	case_destroyed_handle();
	atomic_store_explicit(&cases_done, 1, memory_order_release);
	/* The second character can arrive only through the first's last ack. */
	case_pending_bind();
	case_uart("erx: irq: type another\n");
	case_holder();
	say("erx: irq: done\n");
	erx_fiasco_end(ERX_FIASCO_END_ASKED_OFF, NULL);
}

static void
start_executor(void)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	const uint32_t cpus = erx_fiasco_test_cpu_count();
	uint64_t thread;

	start.regs.sp = (uint64_t)(uintptr_t)(executor_stack + sizeof(executor_stack));
	start.regs.pc = (uint64_t)(uintptr_t)executor_main;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	if (erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK ||
	    erx_thread_set_affinity(thread, UINT64_C(1) << (cpus - 1)) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK)
		fail("erx: irq: no executor FAILED\n");
}

/* The executor's slot is the group's first: nothing else here claims one. */
static void
ring_when_parked(void)
{
	const erx_group_stat_t *const status = erx_fiasco_group_status();

	while (atomic_load_explicit(&cases_done, memory_order_acquire) == 0) {
		if (atomic_load_explicit(&ring_wanted, memory_order_acquire) != 0 &&
		    atomic_load_explicit(&status->exec[0].state, memory_order_acquire) == ERX_EXEC_STATE_PARKED) {
			if (atomic_load_explicit(&status->parked, memory_order_relaxed) != 1)
				fail("erx: irq: the status page's parked disagrees FAILED\n");
			atomic_store_explicit(&ring_wanted, 0, memory_order_release);
			trigger(irq_soft);
		}
		erx_fiasco_test_ipc_sleep_us(POLL_US);
	}
}

/* The clock, the page and the wall agree. */
static void
check_time(void)
{
	const erx_time_page_t *const page = erx_time_page();
	const uint64_t before = erx_fiasco_clock_ns();
	const uint64_t now = erx_time_monotonic_ns();
	const uint64_t after = erx_fiasco_clock_ns();
	uint64_t wall;
	uint32_t version;
	uint64_t hz;

	if (!erx_time_page_version_load(page, &version) || version != ERX_TIME_PAGE_VERSION ||
	    !erx_time_page_counter_hz_load(page, &hz) || hz != erx_fiasco_counter_hz())
		fail("erx: irq: the time page's fields disagree FAILED\n");
	if (now < before || now > after)
		fail("erx: irq: the page's clock disagrees with the counter's FAILED\n");
	if (erx_time_set_offset((erx_cap_t){ .raw = erx_fiasco_time_object() }, WALL_NS - erx_time_monotonic_ns()) != ERX_OK || !erx_time_wall_ns(&wall) || wall < WALL_NS ||
	    wall - WALL_NS > PATIENCE_NS)
		fail("erx: irq: the wall clock disagrees FAILED\n");
	say("erx: irq: the time page agrees with the counter\n");
}

static void
bind_objects(void)
{
	const erx_device_spec_t spec = { .peripheral = "pl011", .peripheral_length = 5, .base = UART_PHYS,
	    .size = ERX_PAGE_SIZE, .line_count = 1, .lines = { UART_LINE } };
	const erx_device_peripheral_t *const pl011 = erx_device_peripheral_find(spec.peripheral, spec.peripheral_length);
	erx_device_spec_t too_small = spec;
	uint32_t device, again;
	uint64_t group, unused, gone;

	if (erx_group_create(0, 0, &group) != ERX_OK)
		fail("erx: irq: no group FAILED\n");
	root_group = group;
	/* A second group has no home, so nothing holds it but its handle, which its destroy leaves stale. */
	if (erx_group_create(0, 0, &gone) != ERX_OK || erx_irq_bind(0, gone, 1) != ERX_ESTALE ||
	    erx_object_destroy(gone) != ERX_OK)
		fail("erx: irq: a second group was not a homeless record FAILED\n");
	if (pl011 == NULL)
		fail("erx: irq: the device table has no pl011 FAILED\n");
	/* One byte short of the registers' window, as the generated table states it. */
	too_small.size = pl011->window_size - 1;
	if (erx_device_open(&too_small, NULL, NULL, &device, NULL) != ERX_EINVAL)
		fail("erx: irq: a window smaller than its registers was not refused FAILED\n");
	if (erx_device_open(&spec, NULL, NULL, &device, NULL) != ERX_OK)
		fail("erx: irq: sigma0 refused the UART's registers, or its line is taken FAILED\n");
	uart = erx_device_get(device);
	if (!erx_device_line_irq(uart, 0, &irq_uart) || erx_device_line_irq(uart, 1, &unused))
		fail("erx: irq: the record has the wrong lines FAILED\n");
	say("erx: irq: sigma0 gave the UART's registers\n");
	say("erx: irq: the UART's receive line is free\n");
	if (erx_device_open(&spec, NULL, NULL, &again, NULL) != ERX_OK || again != device)
		fail("erx: irq: a second open was not the same device FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq_soft, NULL) != ERX_OK ||
	    erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq_other, NULL) != ERX_OK)
		fail("erx: irq: no software object FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_LINE, UART_LINE, &unused, NULL) != ERX_EBUSY)
		fail("erx: irq: a second object on the line was not refused FAILED\n");
	if (erx_irq_bind(irq_uart, group, LABEL_UART) != ERX_OK || erx_irq_bind(irq_soft, group, LABEL_SOFT) != ERX_OK ||
	    erx_irq_bind(irq_other, group, LABEL_OTHER) != ERX_OK)
		fail("erx: irq: the service refused a bind FAILED\n");
	if (erx_irq_bind(UINT64_C(1) << 40, group, 0) != ERX_ESTALE ||
	    erx_irq_bind(irq_soft, gone, 0) != ERX_ESTALE || erx_irq_ack(UINT64_C(1) << 40) != ERX_ESTALE ||
	    erx_irq_trigger(UINT64_C(1) << 40) != ERX_ESTALE)
		fail("erx: irq: a malformed call was not refused FAILED\n");
	if (erx_group_take_ready(1) != ERX_ETYPE)
		fail("erx: irq: a worker's take_ready was not refused FAILED\n");
	if (erx_park(0, 0, 0) != ERX_ETYPE)
		fail("erx: irq: a worker's park was not refused FAILED\n");
	uart_set_field("imsc", "rxim");
	uart_set_field("imsc", "rtim");
}

/* A new physical object over a device's page, mapped read-write at a fresh place of the root's own space. */
static uint64_t
window_mapped(uint64_t phys, uint64_t *object)
{
	uint64_t addr;

	if (erx_mem_create_physical(0, 0, phys, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, object) != ERX_OK ||
	    erx_vm_reserve(ERX_CAP_SELF, 0, ERX_PAGE_SIZE, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, *object, 0, ERX_PROT_RW) != ERX_OK)
		fail("erx: irq: a window over a device was not made and mapped FAILED\n");
	return (addr);
}

static uint32_t
window_id(uint64_t addr)
{
	return (*(volatile const uint32_t *)(uintptr_t)(addr + ID_OFFSET));
}

static void
window_end(uint64_t object, uint64_t addr)
{
	if (erx_vm_release(ERX_CAP_SELF, addr, ERX_PAGE_SIZE) != ERX_OK || erx_object_destroy(object) != ERX_OK)
		fail("erx: irq: a window was not unmapped and destroyed FAILED\n");
}

/*
 * The device window (liberx/backend/fiasco/vm.c, erx_fiasco_vm_physical_create): each
 * physical object maps its registers at a fresh range of the root's device window, which
 * goes back when the object ends, so a holder that makes its window again each life spends
 * none of it, where a window that kept every object's pages would run out within the
 * rounds. Two live objects over the UART each have their own range: ending one, its range
 * unmapped from every space, leaves the other's mapping reading the UART. A third object,
 * over the RTC, takes the lowest free range, the ended one's, and must read the RTC there,
 * not the UART that range showed before.
 */
static void
check_device_window(void)
{
	uint64_t first, second, third, first_at, second_at, third_at;
	uint32_t id;
	int status;

	for (uint32_t round = 0; round < WINDOW_ROUNDS; round++) {
		status = erx_mem_create_physical(0, 0, UART_PHYS, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, &first);
		if (status != ERX_OK) {
			report("erx: irq: a create again of the UART's window: round and status", round, (uint64_t)(int64_t)status);
			fail("erx: irq: a window made again spent the device window FAILED\n");
		}
		if (erx_object_destroy(first) != ERX_OK)
			fail("erx: irq: a window was not destroyed FAILED\n");
	}
	first_at = window_mapped(UART_PHYS, &first);
	second_at = window_mapped(UART_PHYS, &second);
	id = window_id(second_at);
	if (window_id(first_at) != id)
		fail("erx: irq: two windows over one page read differently FAILED\n");
	window_end(first, first_at);
	if (window_id(second_at) != id)
		fail("erx: irq: ending one window changed what another reads FAILED\n");
	third_at = window_mapped(RTC_PHYS, &third);
	if (window_id(third_at) == id || window_id(second_at) != id)
		fail("erx: irq: a window over a freed range reads the device before it FAILED\n");
	window_end(second, second_at);
	window_end(third, third_at);
	say("erx: irq: a window made again spends no device window\n");
}

/*
 * ERX_IRQ_MSI over QEMU virt's MSI frame, which this root, reading no manifest, sets
 * from config/platforms/qemu-virt.json's msi_frame: each line from the frame's first
 * with the frame's doorbell, ERX_ELIMIT once every line has an object, a destroyed
 * object's line taken again, and a selector refused. No MSI arrives here: raising one
 * is the pcie suite's (docs/design-pcie.md, "The pcie QEMU suite").
 */
static void
check_msi(void)
{
	const erx_mf_msi_frame_t frame = { .base = MSI_FRAME_BASE, .first = MSI_FIRST, .count = MSI_COUNT };
	uint64_t objects[MSI_COUNT], extra;
	erx_msi_message_t message;
	int status;

	if (!erx_fiasco_irq_msi_frame(&frame))
		fail("erx: irq: the MSI frame was refused FAILED\n");
	for (uint32_t index = 0; index < MSI_COUNT; index++) {
		status = erx_irq_create(0, 0, ERX_IRQ_MSI, 0, &objects[index], &message);
		if (status != ERX_OK) {
			report("erx: irq: an MSI create's status and line", (uint64_t)(int64_t)status, MSI_FIRST + index);
			fail("erx: irq: the frame refused a free line FAILED\n");
		}
		if (message.address != MSI_FRAME_BASE + MSI_DOORBELL || message.data != MSI_FIRST + index)
			fail("erx: irq: an MSI's message is not the frame's doorbell and its lowest free line FAILED\n");
	}
	if (erx_irq_create(0, 0, ERX_IRQ_MSI, 0, &extra, NULL) != ERX_ELIMIT)
		fail("erx: irq: an MSI past the frame's last line was not refused FAILED\n");
	if (erx_object_destroy(objects[0]) != ERX_OK || erx_irq_create(0, 0, ERX_IRQ_MSI, 0, &objects[0], &message) != ERX_OK ||
	    message.data != MSI_FIRST)
		fail("erx: irq: a destroyed MSI's line was not taken again FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_MSI, 1, &extra, NULL) != ERX_EINVAL)
		fail("erx: irq: an MSI that names a line was not refused FAILED\n");
	for (uint32_t index = 0; index < MSI_COUNT; index++)
		if (erx_object_destroy(objects[index]) != ERX_OK)
			fail("erx: irq: an MSI object was not destroyed FAILED\n");
	say("erx: irq: MSI lines come from the frame's lowest free one\n");
}

void
erx_fiasco_root_main(void)
{
	static erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size, 0, NULL, ERX_FIASCO_ROOT_SLICE_US);
	if (reason != NULL) {
		say(reason);
		erx_fiasco_end(ERX_FIASCO_END_ASKED_OFF, NULL);
	}
	if (erx_fiasco_launcher_find(&pack, HOLDER_PROGRAM, &holder_entry) != ERX_OK)
		fail("erx: irq: the archive holds no holder program FAILED\n");
	check_time();
	bind_objects();
	check_device_window();
	check_msi();
	check_object_space();
	start_executor();
	ring_when_parked();
	/* The executor ends the machine: this thread leaves its CPU to it. */
	erx_fiasco_sleep_forever();
}
