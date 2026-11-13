/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's NIF calls (docs/design-runtime.md, "The device NIF"): opening a
 * device, which interns its table's names as atoms for the BIFs, binding a line to the
 * calling process and naming the process a line is bound to, and a device's queues: creating one, the device's initialisation, posting a
 * chain and completing what the device returned. A binding is a resource monitoring that process, kept by the line's
 * entry, which every record naming the line shares: its exit unbinds the line unless a later binding has moved it, so the late exit of a crashed driver never
 * undoes its successor's binding.
 *
 * One lock serialises opens, everything a binding changes and every queue call. It is taken before the event
 * table's lock and held across service calls; a dispatch, which holds the event table's
 * lock, never takes it.
 */

#define STATIC_ERLANG_NIF 1

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "erl_nif.h"
#include "erx_event.h"

#include "erx_device.h"
#include "liberx/backend/api.h"

#define ATOM_TEXT_MAX	64u

/*
 * A line's binding. The reference enif_alloc_resource gives lasts as long as the monitor:
 * whoever ends the monitor releases it, binding_down when it fired and retire_former when a
 * demonitor got there first. ERTS's monitor holds no reference of its own.
 */
typedef struct binding {
	uint32_t	device;		/* the record and its line the binding was made through */
	uint32_t	line;
	uint32_t	entry;
	uint32_t	label;
	ErlNifPid	pid;
	ErlNifMonitor	monitor;
} binding_t;

static ErlNifMutex *device_lock;
static ErlNifResourceType *binding_type;
static binding_t *bindings[ERX_DEVICE_LINE_ENTRIES_MAX];

static ERL_NIF_TERM
status_error(ErlNifEnv *env, int status)
{
	const char *name;

	switch (status) {
	case ERX_EINVAL:	name = "einval"; break;
	case ERX_ENOTSUP:	name = "enotsup"; break;
	case ERX_ENOMEM:	name = "enomem"; break;
	case ERX_EBUSY:		name = "ebusy"; break;
	case ERX_ERANGE:	name = "erange"; break;
	case ERX_ERIGHTS:	name = "erights"; break;
	case ERX_ELIMIT:	name = "elimit"; break;
	case ERX_EWOULDBLOCK:	name = "full"; break;
	case ERX_ECORRUPT:	name = "broken"; break;
	default:
		return (enif_make_tuple2(env, enif_make_atom(env, "error"),
		    enif_make_tuple2(env, enif_make_atom(env, "status"), enif_make_int(env, status))));
	}
	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, name)));
}

/* A tuple of `arity` whose first element is the atom `tag`, and its elements. */
static bool
tagged(ErlNifEnv *env, ERL_NIF_TERM term, const char *tag, int arity, const ERL_NIF_TERM **parts)
{
	int found;

	return (enif_get_tuple(env, term, &found, parts) && found == arity &&
	    enif_is_identical((*parts)[0], enif_make_atom(env, tag)));
}

/*
 * `{object, Window, Offset, Size}` for a given device, `{physical, Base, Size}`, or `stand_in`
 * for a hosted test's plain memory.
 */
static bool
decode_window(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_spec_t *spec)
{
	const ERL_NIF_TERM *parts;
	ErlNifUInt64 window, base, size;

	if (enif_is_identical(term, enif_make_atom(env, "stand_in"))) {
		spec->form = ERX_DEVICE_FORM_STAND_IN;
		return (true);
	}
	if (tagged(env, term, "object", 4, &parts) && enif_get_uint64(env, parts[1], &window) &&
	    enif_get_uint64(env, parts[2], &base) && enif_get_uint64(env, parts[3], &size)) {
		spec->form = ERX_DEVICE_FORM_GIVEN;
		spec->window = window;
	} else if (!tagged(env, term, "physical", 3, &parts) || !enif_get_uint64(env, parts[1], &base) ||
	    !enif_get_uint64(env, parts[2], &size)) {
		return (false);
	}
	spec->base = base;
	spec->size = size;
	return (true);
}

/*
 * A given device's line is `{object, Irq}`; any other's is its selector. A line two devices
 * of the unit name is marked `{shared, Line}` by the record's writer.
 */
static bool
decode_line(ErlNifEnv *env, ERL_NIF_TERM term, const erx_device_spec_t *spec, uint64_t *line, bool *shared)
{
	const ERL_NIF_TERM *parts;
	ErlNifUInt64 value;

	*shared = tagged(env, term, "shared", 2, &parts);
	if (*shared)
		term = parts[1];
	if (spec->form == ERX_DEVICE_FORM_GIVEN) {
		if (!tagged(env, term, "object", 2, &parts))
			return (false);
		term = parts[1];
	}
	if (!enif_get_uint64(env, term, &value))
		return (false);
	*line = value;
	return (true);
}

/* A given device's `memory => {object, Memory, Bytes}`, Bytes nonzero, which no other form has. */
static bool
decode_memory(ErlNifEnv *env, ERL_NIF_TERM map, erx_device_spec_t *spec)
{
	const ERL_NIF_TERM *parts;
	ERL_NIF_TERM value;
	ErlNifUInt64 memory, bytes;

	if (!enif_get_map_value(env, map, enif_make_atom(env, "memory"), &value))
		return (true);
	if (spec->form != ERX_DEVICE_FORM_GIVEN || !tagged(env, value, "object", 3, &parts) ||
	    !enif_get_uint64(env, parts[1], &memory) || !enif_get_uint64(env, parts[2], &bytes) || bytes == 0)
		return (false);
	spec->memory = memory;
	spec->memory_size = bytes;
	return (true);
}

/* #{peripheral := atom(), window := window(), lines := [line() | {shared, line()}], memory => memory()}. */
static bool
decode_spec(ErlNifEnv *env, ERL_NIF_TERM term, char *peripheral, erx_device_spec_t *spec)
{
	ERL_NIF_TERM value, list, head;
	unsigned length;

	if (!enif_get_map_value(env, term, enif_make_atom(env, "peripheral"), &value))
		return (false);
	const int written = enif_get_atom(env, value, peripheral, ATOM_TEXT_MAX, ERL_NIF_LATIN1);

	if (written <= 0)
		return (false);
	spec->peripheral = peripheral;
	spec->peripheral_length = (size_t)written - 1;
	if (!enif_get_map_value(env, term, enif_make_atom(env, "window"), &value) || !decode_window(env, value, spec))
		return (false);
	if (!enif_get_map_value(env, term, enif_make_atom(env, "lines"), &list) ||
	    !enif_get_list_length(env, list, &length) || length > ERX_DEVICE_LINES_MAX)
		return (false);
	spec->line_count = length;
	for (unsigned index = 0; index < length; index++) {
		if (!enif_get_list_cell(env, list, &head, &list) || !decode_line(env, head, spec, &spec->lines[index], &spec->shared[index]))
			return (false);
	}
	return (decode_memory(env, term, spec));
}

static ERL_NIF_TERM
open_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	uintptr_t register_keys[ERX_DEVICE_REGISTERS_MAX], field_keys[ERX_DEVICE_FIELDS_MAX];
	char peripheral_name[ATOM_TEXT_MAX];
	erx_device_spec_t spec = { 0 };
	const erx_device_peripheral_t *peripheral;
	uint32_t device;
	int status;

	(void)argc;
	if (!decode_spec(env, argv[0], peripheral_name, &spec))
		return (enif_make_badarg(env));
	peripheral = erx_device_peripheral_find(spec.peripheral, spec.peripheral_length);
	if (peripheral == NULL)
		return (enif_make_badarg(env));
	/* The table's names, which only the checked-in SVD files choose. */
	for (uint32_t index = 0; index < peripheral->register_count; index++)
		register_keys[index] = (uintptr_t)enif_make_atom(env, peripheral->registers[index].name);
	for (uint32_t index = 0; index < peripheral->field_count; index++)
		field_keys[index] = (uintptr_t)enif_make_atom(env, peripheral->fields[index].name);
	enif_mutex_lock(device_lock);
	status = erx_device_open(&spec, register_keys, field_keys, &device);
	enif_mutex_unlock(device_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, device)));
}

/* All or nothing: the label is registered, the process monitored and the object reporting the label. */
static int
start_binding(ErlNifEnv *env, binding_t *binding, ERL_NIF_TERM message, uint64_t irq)
{
	ErlNifPid self;
	int status;

	enif_self(env, &self);
	binding->pid = self;
	status = erx_event_register_process(&self, message, &binding->label);
	if (status != ERX_OK)
		return (status);
	/* Only a process past its exit is unmonitorable, and this one is running this call. */
	if (enif_monitor_process(env, binding, &self, &binding->monitor) != 0) {
		erx_event_unregister(binding->label);
		return (ERX_EINVAL);
	}
	status = erx_irq_bind(irq, ERX_CAP_SELF, binding->label);
	if (status != ERX_OK) {
		(void)enif_demonitor_process(env, binding, &binding->monitor);
		erx_event_unregister(binding->label);
	}
	return (status);
}

/* The object reports a later label, so the former binding has nothing left to deliver. */
static void
retire_former(ErlNifEnv *env, binding_t *former)
{
	erx_event_unregister(former->label);
	if (enif_demonitor_process(env, former, &former->monitor) == 0)
		enif_release_resource(former);
}

/* What a refused bind answers: badarg for a line the record lacks, a refusal for the rest. */
static ERL_NIF_TERM
bind_refusal(ErlNifEnv *env, erx_device_bind_t decision)
{
	switch (decision) {
	case ERX_DEVICE_BIND_SHARED:	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "shared")));
	case ERX_DEVICE_BIND_DIRECT:	return (enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "direct")));
	case ERX_DEVICE_BIND_BUSY:	return (status_error(env, ERX_EBUSY));
	case ERX_DEVICE_BIND_OK:
	case ERX_DEVICE_BIND_NO_LINE:
	default:			return (enif_make_badarg(env));
	}
}

/*
 * irq_bind/2 and irq_bind_owner/2: the line's mark decides which of them binds it
 * (erx_device_bind_check), and a bind through the record the line is bound through moves
 * the binding to the caller.
 */
static ERL_NIF_TERM
bind_line(ErlNifEnv *env, const ERL_NIF_TERM argv[], erx_device_binder_t binder)
{
	unsigned device_index, line_index;
	const erx_device_t *device;
	erx_device_bind_t decision;
	binding_t *binding, *former;
	uint32_t entry;
	uint64_t irq;
	int status;

	if (!enif_get_uint(env, argv[0], &device_index) || !enif_get_uint(env, argv[1], &line_index))
		return (enif_make_badarg(env));
	device = erx_device_get(device_index);
	if (device == NULL || !erx_device_line_irq(device, line_index, &irq) || !erx_device_line_entry(device, line_index, &entry))
		return (enif_make_badarg(env));
	binding = enif_alloc_resource(binding_type, sizeof(*binding));
	if (binding == NULL)
		return (status_error(env, ERX_ENOMEM));
	binding->device = device_index;
	binding->line = line_index;
	binding->entry = entry;

	const ERL_NIF_TERM message = enif_make_tuple3(env, enif_make_atom(env, "erx_irq"), argv[0], argv[1]);

	enif_mutex_lock(device_lock);
	former = bindings[entry];
	decision = erx_device_bind_check(device, line_index, binder, former != NULL ? erx_device_get(former->device) : NULL,
	    former != NULL ? former->line : 0);
	if (decision != ERX_DEVICE_BIND_OK) {
		enif_mutex_unlock(device_lock);
		enif_release_resource(binding);
		return (bind_refusal(env, decision));
	}
	status = start_binding(env, binding, message, irq);
	if (status != ERX_OK) {
		enif_mutex_unlock(device_lock);
		enif_release_resource(binding);
		return (status_error(env, status));
	}
	if (former != NULL)
		retire_former(env, former);
	bindings[entry] = binding;
	/* A line a former binder left masked opens for this one; a level still asserted fires at once. */
	status = erx_irq_ack(irq);
	enif_mutex_unlock(device_lock);
	return (status == ERX_OK ? enif_make_atom(env, "ok") : status_error(env, status));
}

static ERL_NIF_TERM
irq_bind_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	return (bind_line(env, argv, ERX_DEVICE_BINDER_DRIVER));
}

static ERL_NIF_TERM
irq_bind_owner_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	(void)argc;
	return (bind_line(env, argv, ERX_DEVICE_BINDER_OWNER));
}

/* irq_holder(Dev, Line): the process the line is bound to, through any record naming it. */
static ERL_NIF_TERM
irq_holder_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned device_index, line_index;
	const erx_device_t *device;
	ERL_NIF_TERM result;
	uint32_t entry;

	(void)argc;
	if (!enif_get_uint(env, argv[0], &device_index) || !enif_get_uint(env, argv[1], &line_index))
		return (enif_make_badarg(env));
	device = erx_device_get(device_index);
	if (device == NULL || !erx_device_line_entry(device, line_index, &entry))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	if (bindings[entry] != NULL)
		result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_pid(env, &bindings[entry]->pid));
	else
		result = enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "unbound"));
	enif_mutex_unlock(device_lock);
	return (result);
}

/*
 * The monitored process exited. A binding that a later one has moved no longer names its
 * line, and the move has done the rest. A refused unbind has no one to tell: the label it
 * would have stopped names nothing, so a delivery under it is dropped.
 */
static void
binding_down(ErlNifEnv *env, void *object, ErlNifPid *pid, ErlNifMonitor *monitor)
{
	binding_t *const binding = object;
	uint64_t irq;

	(void)env;
	(void)pid;
	(void)monitor;
	enif_mutex_lock(device_lock);
	if (bindings[binding->entry] == binding) {
		if (erx_device_line_irq(erx_device_get(binding->device), binding->line, &irq))
			(void)erx_irq_bind(irq, ERX_CAP_NULL, 0);
		erx_event_unregister(binding->label);
		bindings[binding->entry] = NULL;
	}
	enif_mutex_unlock(device_lock);
	enif_release_resource(binding);
}

/* The open device a term names, or NULL. */
static const erx_device_t *
device_of(ErlNifEnv *env, ERL_NIF_TERM term)
{
	unsigned index;

	return (enif_get_uint(env, term, &index) ? erx_device_get(index) : NULL);
}

/* queue_create(Dev, Queue, Size, BufferSize) */
static ERL_NIF_TERM
queue_create_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	unsigned index, size, buffer_size;
	uint32_t queue;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &index) || !enif_get_uint(env, argv[2], &size) ||
	    !enif_get_uint(env, argv[3], &buffer_size))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_queue_create(device, index, size, buffer_size, &queue);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint(env, queue)));
}

/* negotiate(Dev, Wanted) */
static ERL_NIF_TERM
negotiate_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	ErlNifUInt64 wanted;
	uint64_t accepted;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint64(env, argv[1], &wanted))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_negotiate(device, wanted, &accepted);
	enif_mutex_unlock(device_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_uint64(env, accepted)));
}

/*
 * One `{out, Binary}` or `{in, Length}`. An out piece is a binary, never an iolist, so its
 * size is known before anything is copied, and its bytes stay valid for the call as a term of it.
 */
static bool
decode_piece(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_piece_t *piece)
{
	const ERL_NIF_TERM *pair;
	ErlNifBinary bytes;
	unsigned length;
	int arity;

	if (!enif_get_tuple(env, term, &arity, &pair) || arity != 2)
		return (false);
	if (enif_is_identical(pair[0], enif_make_atom(env, "out"))) {
		if (!enif_inspect_binary(env, pair[1], &bytes) || bytes.size > ERX_DEVICE_BUFFER_MAX)
			return (false);
		*piece = (erx_device_piece_t){ .device_writes = false, .data = bytes.data, .length = (uint32_t)bytes.size };
		return (true);
	}
	if (!enif_is_identical(pair[0], enif_make_atom(env, "in")) || !enif_get_uint(env, pair[1], &length))
		return (false);
	*piece = (erx_device_piece_t){ .device_writes = true, .data = NULL, .length = length };
	return (true);
}

/* post(Dev, Q, Tag, Segments) */
static ERL_NIF_TERM
post_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	erx_device_piece_t pieces[ERX_DEVICE_CHAIN_MAX];
	ERL_NIF_TERM list = argv[3], head;
	ErlNifUInt64 tag;
	unsigned queue, count = 0;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &queue) || !enif_get_uint64(env, argv[2], &tag))
		return (enif_make_badarg(env));
	while (enif_get_list_cell(env, list, &head, &list)) {
		if (count == ERX_DEVICE_CHAIN_MAX || !decode_piece(env, head, &pieces[count]))
			return (enif_make_badarg(env));
		count++;
	}
	if (!enif_is_empty_list(env, list))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_post(device, queue, tag, pieces, count);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	return (status == ERX_OK ? enif_make_atom(env, "ok") : status_error(env, status));
}

/* What complete_nif collects: one `{Tag, Binary}` per completion, at most the queue's size. */
typedef struct completions {
	ErlNifEnv	*env;
	uint32_t	count;
	ERL_NIF_TERM	terms[ERX_DEVICE_QUEUE_SIZE_MAX];
} completions_t;

/* A fresh binary for each completion, so no term ever aliases memory the device can write. */
static uint8_t *
completion_sink(void *context, uint64_t tag, uint32_t length)
{
	completions_t *const completions = context;
	ERL_NIF_TERM binary;
	uint8_t *const bytes = enif_make_new_binary(completions->env, length, &binary);

	completions->terms[completions->count++] = enif_make_tuple2(completions->env,
	    enif_make_uint64(completions->env, tag), binary);
	return (bytes);
}

/* complete(Dev, Q) */
static ERL_NIF_TERM
complete_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	completions_t completions = { .env = env };
	unsigned queue;
	uint32_t count;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &queue))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_complete(device, queue, completion_sink, &completions, &count);
	enif_mutex_unlock(device_lock);
	if (status == ERX_EINVAL)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_list_from_array(env, completions.terms, count)));
}

#ifdef ERX_DEVICE_STAND_IN
/* Fires a hosted stand-in's line, as a device would. A native build has no such NIF. */
static ERL_NIF_TERM
stand_in_fire_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned device_index, line_index;
	const erx_device_t *device;
	uint64_t irq;

	(void)argc;
	if (!enif_get_uint(env, argv[0], &device_index) || !enif_get_uint(env, argv[1], &line_index))
		return (enif_make_badarg(env));
	device = erx_device_get(device_index);
	if (device == NULL || !erx_device_line_irq(device, line_index, &irq) || erx_irq_trigger(irq) != ERX_OK)
		return (enif_make_badarg(env));
	return (enif_make_atom(env, "ok"));
}

/* One `{next, Length}` or `{Id, Length}` of stand_in_used/3. */
static bool
decode_used_entry(ErlNifEnv *env, ERL_NIF_TERM term, erx_device_used_entry_t *entry)
{
	const ERL_NIF_TERM *pair;
	unsigned id = 0, length;
	int arity;

	if (!enif_get_tuple(env, term, &arity, &pair) || arity != 2 || !enif_get_uint(env, pair[1], &length))
		return (false);
	entry->next = enif_is_identical(pair[0], enif_make_atom(env, "next"));
	if (!entry->next && !enif_get_uint(env, pair[0], &id))
		return (false);
	entry->id = id;
	entry->length = length;
	return (true);
}

/* stand_in_used(Dev, Q, Entries): a hosted stand-in's device returns entries on a queue, honest or not. */
static ERL_NIF_TERM
stand_in_used_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const erx_device_t *const device = device_of(env, argv[0]);
	erx_device_used_entry_t entries[ERX_DEVICE_QUEUE_SIZE_MAX];
	ERL_NIF_TERM list = argv[2], head;
	unsigned queue, count = 0;
	int status;

	(void)argc;
	if (device == NULL || !enif_get_uint(env, argv[1], &queue))
		return (enif_make_badarg(env));
	while (enif_get_list_cell(env, list, &head, &list)) {
		if (count == ERX_DEVICE_QUEUE_SIZE_MAX || !decode_used_entry(env, head, &entries[count]))
			return (enif_make_badarg(env));
		count++;
	}
	if (!enif_is_empty_list(env, list))
		return (enif_make_badarg(env));
	enif_mutex_lock(device_lock);
	status = erx_device_stand_in_used(device, queue, entries, count);
	enif_mutex_unlock(device_lock);
	return (status == ERX_OK ? enif_make_atom(env, "ok") : enif_make_badarg(env));
}
#endif

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	static const ErlNifResourceTypeInit binding_init = { .down = binding_down, .members = 3 };

	(void)priv;
	(void)info;
	device_lock = enif_mutex_create("erx_device");
	binding_type = enif_init_resource_type(env, "erx_device_binding", &binding_init, ERL_NIF_RT_CREATE, NULL);
	return (device_lock == NULL || binding_type == NULL ? 1 : 0);
}

static ErlNifFunc nif_funcs[] = {
	{ "open", 1, open_nif, 0 },
	{ "irq_bind", 2, irq_bind_nif, 0 },
	{ "irq_bind_owner", 2, irq_bind_owner_nif, 0 },
	{ "irq_holder", 2, irq_holder_nif, 0 },
	{ "queue_create", 4, queue_create_nif, 0 },
	{ "negotiate", 2, negotiate_nif, 0 },
	{ "post", 4, post_nif, 0 },
	{ "complete", 2, complete_nif, 0 },
#ifdef ERX_DEVICE_STAND_IN
	{ "stand_in_fire", 2, stand_in_fire_nif, 0 },
	{ "stand_in_used", 3, stand_in_used_nif, 0 },
#endif
};

ERL_NIF_INIT(erx_device, nif_funcs, load, NULL, NULL, NULL)
