/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Interrupts through the readiness interface (docs/design-stopgap.md, "Interrupts and
 * readiness", "Verification"), as the root task; tools/lib/erx/native_irq.rb judges the
 * transcript and types the characters. The first thread rings the software object when
 * the executor is seen parked, a handshake that needs no sleep; the executor runs on
 * another CPU when there is one, so a wake crosses CPUs.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/vm.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"

/* QEMU virt's PL011: its registers, and its receive line, SPI 1. */
#define UART_PHYS	UINT64_C(0x9000000)
#define UART_LINE	33u

#define LABEL_UART	UINT64_C(0x55a0)
#define LABEL_SOFT	UINT64_C(0x55b1)
#define LABEL_OTHER	UINT64_C(0x55c2)
#define LABEL_MOVED	UINT64_C(0x55d3)

#define NS_PER_MS	UINT64_C(1000000)
/* How long a park waits before the case says the wake was lost. */
#define PATIENCE_NS	(UINT64_C(30000) * NS_PER_MS)
#define TIMED_PARK_NS	(UINT64_C(20) * NS_PER_MS)
#define RING_ROUNDS	1000u
#define REPEATS		3u
#define STACK_BYTES	16384u
#define WALL_NS		(UINT64_C(1800000000) * UINT64_C(1000000000))

void erx_fiasco_root_main(void);

static _Alignas(16) uint8_t executor_stack[STACK_BYTES];
static uint64_t irq_uart, irq_soft, irq_other;
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
	erx_fiasco_machine_off();
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
		fail("erx: irq: the service refused a trigger FAILED\n");
}

/* Fires an object and waits for the dispatcher to run its trigger, seen as the epoch moving. */
static void
trigger_and_see(uint64_t irq)
{
	const uint64_t before = group_epoch();

	trigger(irq);
	while (group_epoch() == before)
		erx_yield();
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
case_uart(const char *prompt)
{
	uint64_t label;
	uint64_t byte;

	say(prompt);
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
executor_main(uint64_t unused)
{
	(void)unused;
	case_parked_wake();
	case_trigger_before_park();
	case_once_and_order();
	case_move_and_unbind();
	case_timed_park();
	case_rounds();
	atomic_store_explicit(&cases_done, 1, memory_order_release);
	case_uart("erx: irq: type a character\n");
	/* A restarted driver's path on a real line: an unbind masks it, and the bind opens it. */
	if (erx_irq_bind(irq_uart, ERX_CAP_NULL, 0) != ERX_OK || erx_irq_bind(irq_uart, ERX_CAP_SELF, LABEL_UART) != ERX_OK)
		fail("erx: irq: the line was not bound again FAILED\n");
	case_uart("erx: irq: type another\n");
	say("erx: irq: done\n");
	erx_fiasco_machine_off();
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
		erx_yield();
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

	if (atomic_load_explicit(&page->version, memory_order_relaxed) != 1 ||
	    atomic_load_explicit(&page->counter_hz, memory_order_relaxed) != erx_fiasco_counter_hz())
		fail("erx: irq: the time page's fields disagree FAILED\n");
	if (now < before || now > after)
		fail("erx: irq: the page's clock disagrees with the counter's FAILED\n");
	if (erx_time_set_wall(WALL_NS) != ERX_OK || !erx_time_wall_ns(&wall) || wall < WALL_NS ||
	    wall - WALL_NS > PATIENCE_NS)
		fail("erx: irq: the wall clock disagrees FAILED\n");
	say("erx: irq: the time page agrees with the counter\n");
}

static void
bind_objects(void)
{
	const erx_device_spec_t spec = { .peripheral = "pl011", .peripheral_length = 5, .base = UART_PHYS,
	    .size = ERX_PAGE_SIZE, .line_count = 1, .lines = { UART_LINE } };
	erx_device_spec_t too_small = spec;
	uint32_t device, again;
	uint64_t group, unused;

	if (erx_group_create(0, 0, &group) != ERX_OK)
		fail("erx: irq: no group FAILED\n");
	if (erx_group_create(0, 0, &unused) != ERX_ELIMIT)
		fail("erx: irq: a second group was not refused FAILED\n");
	too_small.size = ERX_PAGE_SIZE / 2;
	if (erx_device_open(&too_small, NULL, NULL, &device) != ERX_EINVAL)
		fail("erx: irq: a window smaller than its registers was not refused FAILED\n");
	if (erx_device_open(&spec, NULL, NULL, &device) != ERX_OK)
		fail("erx: irq: sigma0 refused the UART's registers, or its line is taken FAILED\n");
	uart = erx_device_get(device);
	if (!erx_device_line_irq(uart, 0, &irq_uart) || erx_device_line_irq(uart, 1, &unused))
		fail("erx: irq: the record has the wrong lines FAILED\n");
	say("erx: irq: sigma0 gave the UART's registers\n");
	say("erx: irq: the UART's receive line is free\n");
	if (erx_device_open(&spec, NULL, NULL, &again) != ERX_OK || again != device)
		fail("erx: irq: a second open was not the same device FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq_soft) != ERX_OK ||
	    erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq_other) != ERX_OK)
		fail("erx: irq: no software object FAILED\n");
	if (erx_irq_create(0, 0, ERX_IRQ_LINE, UART_LINE, &unused) != ERX_EBUSY)
		fail("erx: irq: a second object on the line was not refused FAILED\n");
	if (erx_irq_bind(irq_uart, group, LABEL_UART) != ERX_OK || erx_irq_bind(irq_soft, group, LABEL_SOFT) != ERX_OK ||
	    erx_irq_bind(irq_other, group, LABEL_OTHER) != ERX_OK)
		fail("erx: irq: the service refused a bind FAILED\n");
	if (erx_irq_bind(77, group, 0) != ERX_EINVAL ||
	    erx_irq_bind(irq_soft, group + 1, 0) != ERX_EINVAL || erx_irq_ack(77) != ERX_EINVAL ||
	    erx_irq_trigger(77) != ERX_EINVAL)
		fail("erx: irq: a malformed call was not refused FAILED\n");
	if (erx_group_take_ready(1) != ERX_ETYPE)
		fail("erx: irq: a worker's take_ready was not refused FAILED\n");
	if (erx_park(0, 0, 0) != ERX_ETYPE)
		fail("erx: irq: a worker's park was not refused FAILED\n");
	uart_set_field("imsc", "rxim");
	uart_set_field("imsc", "rtim");
}

void
erx_fiasco_root_main(void)
{
	const char *reason = erx_fiasco_root_up(NULL, 0);

	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	check_time();
	bind_objects();
	start_executor();
	ring_when_parked();
	/* The executor ends the machine: this thread leaves its CPU to it. */
	for (;;)
		erx_yield();
}
