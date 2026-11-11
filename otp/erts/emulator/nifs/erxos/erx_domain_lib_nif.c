/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_domain_lib: the domain service's way into the system domain's domain
 * library (docs/design-system.md, "The domain library"; include/erx/dom_lib.h).
 * Each entry is a dirty CPU NIF, since none waits on anything but a call to
 * the backend or the lock, and runs under lib_lock, the library's one lock,
 * which the fault thread takes too while it handles a record.
 *
 * The fault thread is an ERTS thread (enif_thread_create) this module starts
 * at load, bound to the library's fault gate. It waits at the gate outside
 * the lock, hands each record to the library under it, and sends the domain
 * service's registered process {domain_ended, Id, End, Record} for every
 * end, with enif_send and a NULL env, as any thread that is not a scheduler
 * does (erl_nif.c).
 *
 * The library is the one the root's start built (erx_dom_lib_system). Where
 * there is none, in a domain's runtime and a hosted runtime
 * (liberx/backend/core/dom_lib_none.c), no thread starts and every
 * well-formed call, register included, answers {error, enotsup}.
 *
 * The process that registers is the one that hears of every end, and the
 * only one that may change the library: every entry that does (create,
 * configured_create, session_create, start, stop, retire, connect,
 * disconnect) asks
 * caller_is_service first, under the lock, and answers {error, erights} to
 * any other caller. So only the process that registered drives the
 * library, and no domain the module made can end with no one to hear of
 * it. crash, which reads an ended domain's crash area, asks the same, since
 * the dump holds that domain's data. Which process registers is the domain service's to win: it registers
 * at its start, and a registration while it lives is refused (TODO.md, the
 * domain service's trust in system-domain processes).
 *
 * Every term an entry decodes comes from an Erlang caller and is checked
 * here for shape only: a map with exactly the keys its reader takes, each
 * an integer of its field's width, a binary that fits, or a pid of this
 * node. The library
 * validates every value against its view. No atom is made from a caller's
 * term: the keys looked up are this file's own names.
 */

#define STATIC_ERLANG_NIF 1

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erl_nif.h"
#include "sys.h"
#include "global.h"

#include "erx/abi.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "liberx/backend/api.h"

static ErlNifMutex *lib_lock;		/* made once, by the first load */
static erx_dom_lib_t *lib;		/* set once at load */
static ErlNifPid service;		/* under lib_lock: who hears of ends */
static bool service_set;		/* under lib_lock */

static ERL_NIF_TERM
atom(ErlNifEnv *env, const char *name)
{
	return (enif_make_atom(env, name));
}

/*
 * {error, Name} with the ABI file's name of status, e-prefixed (einval),
 * or {error, {status, N}}.
 */
static ERL_NIF_TERM
status_error(ErlNifEnv *env, erx_status_t status)
{
	const char *const name = erx_status_name(status);
	char text[32] = "e";

	if (name == NULL || strlen(name) + 2 > sizeof(text))
		return (enif_make_tuple2(env, atom(env, "error"),
		    enif_make_tuple2(env, atom(env, "status"), enif_make_int(env, status))));
	memcpy(&text[1], name, strlen(name) + 1);
	return (enif_make_tuple2(env, atom(env, "error"), atom(env, text)));
}

static ERL_NIF_TERM
status_term(ErlNifEnv *env, erx_status_t status)
{
	return (status == ERX_OK ? atom(env, "ok") : status_error(env, status));
}

/*
 * A map being decoded. Each key a read finds counts in taken, and
 * reader_done holds only when taken is the map's size, so a key no read
 * asked for (a misspelling, a field the library sets itself) refuses the
 * whole map instead of being ignored.
 */
typedef struct map_reader {
	ErlNifEnv	*env;
	ERL_NIF_TERM	 map;
	size_t		 taken;
} map_reader_t;

static bool
reader_open(ErlNifEnv *env, ERL_NIF_TERM map, map_reader_t *reader)
{
	*reader = (map_reader_t){ .env = env, .map = map, .taken = 0 };
	return (enif_is_map(env, map));
}

static bool
reader_has(const map_reader_t *reader, const char *key)
{
	ERL_NIF_TERM value;

	return (enif_get_map_value(reader->env, reader->map, atom(reader->env, key), &value));
}

/* The value at key, counted as taken; false when the key is absent. */
static bool
reader_take(map_reader_t *reader, const char *key, ERL_NIF_TERM *value)
{
	if (!enif_get_map_value(reader->env, reader->map, atom(reader->env, key), value))
		return (false);
	reader->taken++;
	return (true);
}

static bool
reader_done(const map_reader_t *reader)
{
	size_t size;

	return (enif_get_map_size(reader->env, reader->map, &size) && size == reader->taken);
}

/* A required non-negative integer of at most 64 bits. */
static bool
read_u64(map_reader_t *reader, const char *key, uint64_t *value)
{
	ERL_NIF_TERM term;
	ErlNifUInt64 wide;

	if (!reader_take(reader, key, &term) || !enif_get_uint64(reader->env, term, &wide))
		return (false);
	*value = wide;
	return (true);
}

/* A required non-negative integer of at most 32 bits. */
static bool
read_u32(map_reader_t *reader, const char *key, uint32_t *value)
{
	uint64_t wide;

	if (!read_u64(reader, key, &wide) || wide > UINT32_MAX)
		return (false);
	*value = (uint32_t)wide;
	return (true);
}

/* An optional one: 0 when key is absent. */
static bool
read_u32_or_zero(map_reader_t *reader, const char *key, uint32_t *value)
{
	*value = 0;
	return (!reader_has(reader, key) || read_u32(reader, key, value));
}

/*
 * A required grant: a map of quota_ns and cpuset, and capacity_mcpu (0 when
 * absent), and nothing else.
 */
static bool
read_grant(map_reader_t *reader, const char *key, erx_grant_t *grant)
{
	map_reader_t inner;
	ERL_NIF_TERM term;
	uint64_t quota, cpuset;
	uint32_t capacity;

	if (!reader_take(reader, key, &term) || !reader_open(reader->env, term, &inner) ||
	    !read_u64(&inner, "quota_ns", &quota) || !read_u64(&inner, "cpuset", &cpuset) ||
	    !read_u32_or_zero(&inner, "capacity_mcpu", &capacity) || !reader_done(&inner))
		return (false);
	*grant = (erx_grant_t){ .quota_ns = quota, .cpuset = cpuset, .capacity_mcpu = capacity };
	return (true);
}

/*
 * The request's arguments and environment: args and env, binaries of
 * NUL-ended strings, side by side in spec->strings. False for either missing
 * or for the two beyond ERX_BOOT_STRINGS_MAX together.
 */
static bool
read_strings(map_reader_t *reader, erx_dom_spec_t *spec)
{
	ERL_NIF_TERM args_term, env_term;
	ErlNifBinary args, envs;

	if (!reader_take(reader, "args", &args_term) || !reader_take(reader, "env", &env_term) ||
	    !enif_inspect_binary(reader->env, args_term, &args) ||
	    !enif_inspect_binary(reader->env, env_term, &envs) ||
	    args.size > sizeof(spec->strings) || envs.size > sizeof(spec->strings) - args.size)
		return (false);
	memcpy(spec->strings, args.data, args.size);
	memcpy(&spec->strings[args.size], envs.data, envs.size);
	spec->args_len = (uint32_t)args.size;
	spec->env_len = (uint32_t)envs.size;
	return (true);
}
/*
 * The runtime limits a request may give, in the bit order of given that
 * erx_dom_plan_request reads (dom_core.c, dom_spec_request). dom_core.c pins
 * erx_runtime_limits_t's layout to ERX_DOM_LIMITS_FIELDS fields, and the
 * assertion below holds this table to that count.
 */
#define LIMIT(name)	{ #name, offsetof(erx_runtime_limits_t, name),	\
			  sizeof(((erx_runtime_limits_t *)0)->name) }
static const struct limit_field {
	const char	*name;
	size_t		 offset;
	size_t		 size;		/* 4 or 8 */
} limit_fields[] = {
	LIMIT(max_frame),	LIMIT(max_message_heap),
	LIMIT(funnel_depth),	LIMIT(exports),
	LIMIT(tmp),		LIMIT(overlay),
	LIMIT(atoms),		LIMIT(foreign_atoms),
	LIMIT(processes),	LIMIT(peer_held),
	LIMIT(peer_held_total),
};
#undef LIMIT
_Static_assert(sizeof(limit_fields) / sizeof(limit_fields[0]) == ERX_DOM_LIMITS_FIELDS,
    "every runtime limit a request may give is decoded");

/*
 * The optional limits map: each field it names sets that field and its bit
 * of given; a field it leaves out is the principal's default.
 */
static bool
read_limits(map_reader_t *reader, erx_runtime_limits_t *limits, uint32_t *given)
{
	map_reader_t inner;
	ERL_NIF_TERM term;

	memset(limits, 0, sizeof(*limits));
	*given = 0;
	if (!reader_has(reader, "limits"))
		return (true);
	if (!reader_take(reader, "limits", &term) || !reader_open(reader->env, term, &inner))
		return (false);
	for (uint32_t bit = 0; bit < ERX_DOM_LIMITS_FIELDS; bit++) {
		const struct limit_field *const field = &limit_fields[bit];
		uint64_t wide;
		uint32_t narrow;

		if (!reader_has(&inner, field->name))
			continue;
		if (field->size == sizeof(uint64_t)) {
			if (!read_u64(&inner, field->name, &wide))
				return (false);
			memcpy((char *)limits + field->offset, &wide, sizeof(wide));
		} else {
			if (!read_u32(&inner, field->name, &narrow))
				return (false);
			memcpy((char *)limits + field->offset, &narrow, sizeof(narrow));
		}
		*given |= UINT32_C(1) << bit;
	}
	return (reader_done(&inner));
}

/*
 * Whether the calling process is the registered one, the domain service.
 * Every entry that changes the library asks this first, under lib_lock.
 */
static bool
caller_is_service(ErlNifEnv *env)
{
	ErlNifPid self;

	return (service_set && enif_self(env, &self) != NULL && enif_compare_pids(&self, &service) == 0);
}

/*
 * The domain's name: name, a binary of 1 to ERX_DOM_NAME_MAX bytes, which
 * the library checks is an identifier.
 */
static bool
read_name(map_reader_t *reader, erx_dom_spec_t *spec)
{
	ERL_NIF_TERM term;
	ErlNifBinary name;

	if (!reader_take(reader, "name", &term) || !enif_inspect_binary(reader->env, term, &name) ||
	    name.size > sizeof(spec->name))
		return (false);
	memcpy(spec->name, name.data, name.size);
	spec->name_len = (uint32_t)name.size;
	return (true);
}

/*
 * A domain pid, a pid of this node, as the ID and Serial NEW_PID_EXT
 * writes for it (external.c, enc_internal_pid), which the boot page
 * carries to the domain as a pid of the system domain's node.
 */
static bool
domain_pid_from(ErlNifEnv *env, ERL_NIF_TERM term, erx_dom_pid_t *pid)
{
	ErlNifPid local;

	if (!enif_get_local_pid(env, term, &local))
		return (false);
	*pid = (erx_dom_pid_t){ .number = (uint32_t)internal_pid_number(local.pid),
	    .serial = (uint32_t)internal_pid_serial(local.pid) };
	return (true);
}

/*
 * A request's map as an erx_dom_spec_t and its limits. Only its shape is
 * checked here: erx_dom_plan_request validates every value against the
 * library's view before anything is made. The fields the library sets
 * itself (origin, system_lane, crash) are no keys of the map. spaces is
 * given exactly when flags holds ERX_DOM_SPACES.
 */
static bool
spec_from(ErlNifEnv *env, ERL_NIF_TERM map, erx_dom_spec_t *spec, erx_runtime_limits_t *limits,
    uint32_t *given)
{
	map_reader_t reader;
	ERL_NIF_TERM domain_pid;

	memset(spec, 0, sizeof(*spec));
	spec->version = ERX_DOM_SPEC_VERSION;
	if (!reader_open(env, map, &reader) || !read_u32(&reader, "id", &spec->id) ||
	    !read_name(&reader, spec) ||
	    !read_u32(&reader, "principal", &spec->principal) ||
	    !reader_take(&reader, "domain_pid", &domain_pid) || !domain_pid_from(env, domain_pid, &spec->domain_pid) ||
	    !read_u32(&reader, "runtime", &spec->runtime) ||
	    !read_u32(&reader, "release", &spec->release) ||
	    !read_u32(&reader, "release_files", &spec->release_files) ||
	    !read_u64(&reader, "memory", &spec->memory) || !read_u64(&reader, "outer", &spec->outer) ||
	    !read_grant(&reader, "grant", &spec->grant) || !read_u32(&reader, "lane", &spec->lane) ||
	    !read_u32_or_zero(&reader, "connections", &spec->connections) ||
	    !read_u32_or_zero(&reader, "flags", &spec->flags) || !read_strings(&reader, spec) ||
	    !read_limits(&reader, limits, given))
		return (false);
	if ((spec->flags & ERX_DOM_SPACES) != 0) {
		if (!read_grant(&reader, "spaces", &spec->spaces))
			return (false);
	} else if (reader_has(&reader, "spaces")) {
		return (false);
	}
	return (reader_done(&reader));
}

/* A created domain's values as the map create_nif and configured_create_nif return. */
static ERL_NIF_TERM
created_term(ErlNifEnv *env, const erx_dom_created_t *created)
{
	ERL_NIF_TERM keys[10], values[10], result;

	keys[0] = atom(env, "id"), values[0] = enif_make_uint(env, created->id);
	keys[1] = atom(env, "connection"), values[1] = enif_make_uint(env, created->connection);
	keys[2] = atom(env, "side"), values[2] = enif_make_uint64(env, created->side);
	keys[3] = atom(env, "peer_side"), values[3] = enif_make_uint64(env, created->peer_side);
	keys[4] = atom(env, "bell"), values[4] = enif_make_uint64(env, created->bell);
	keys[5] = atom(env, "reader"), values[5] = enif_make_uint(env, created->reader);
	keys[6] = atom(env, "system_lane"), values[6] = enif_make_uint(env, created->system_lane);
	/* The control table's slots and its one writer, for the system side's open. */
	keys[7] = atom(env, "ctl_slots"), values[7] = enif_make_uint(env, created->ctl_slots);
	keys[8] = atom(env, "domain_pid_number"), values[8] = enif_make_uint(env, created->domain_pid.number);
	keys[9] = atom(env, "domain_pid_serial"), values[9] = enif_make_uint(env, created->domain_pid.serial);
	if (!enif_make_map_from_arrays(env, keys, values, 10, &result))
		return (enif_make_badarg(env));
	return (enif_make_tuple2(env, atom(env, "ok"), result));
}

/*
 * The services configured domains serve, [{ServerRow, Name}], and the facet
 * rows, [{Grantee, Name, Server, Limits}], Grantee a configured row, the
 * atom system, or {template, Template} for the sessions made from session
 * template Template, the index a session's origin {session, Template}
 * names, Name the service's name as an atom, Server its server's row
 * or, for a service the system domain serves, the atom system, and Limits
 * the grant's limits by name, each list in manifest order
 * (docs/design-system.md, "Facets a configured domain serves"). The
 * services list leaves out the system domain's own, which no mint serves.
 * A name is a checked identifier of at most 63 bytes from the manifest,
 * never from a request, so the atoms are bounded by the manifest's rows.
 */
static bool
served_terms(ErlNifEnv *env, ERL_NIF_TERM *services, ERL_NIF_TERM *grants)
{
	ERL_NIF_TERM keys[6], values[6], limits, grantee, name, server;
	const erx_dom_service_t *service;
	const erx_dom_facet_t *facet;
	uint32_t index;

	/* Each list built from the last row back, so its head is the first row. */
	*services = enif_make_list(env, 0);
	for (index = lib->view.nservices; index-- > 0;) {
		service = &lib->view.services[index];
		if (service->server == ERX_MF_NONE)
			continue;
		name = enif_make_atom_len(env, service->name, service->name_len);
		*services = enif_make_list_cell(env,
		    enif_make_tuple2(env, enif_make_uint(env, service->server), name), *services);
	}
	*grants = enif_make_list(env, 0);
	for (index = lib->view.nfacets; index-- > 0;) {
		facet = &lib->view.facets[index];
		service = &lib->view.services[facet->service];
		keys[0] = atom(env, "max_request"), values[0] = enif_make_uint(env, facet->max_request);
		keys[1] = atom(env, "in_flight"), values[1] = enif_make_uint(env, facet->in_flight);
		keys[2] = atom(env, "reductions"), values[2] = enif_make_uint64(env, facet->reductions);
		keys[3] = atom(env, "period_ns"), values[3] = enif_make_uint64(env, facet->period_ns);
		keys[4] = atom(env, "max_heap_size"), values[4] = enif_make_uint64(env, facet->max_heap_size);
		keys[5] = atom(env, "queue"), values[5] = enif_make_uint64(env, facet->queue);
		if (!enif_make_map_from_arrays(env, keys, values, 6, &limits))
			return (false);
		switch (facet->grantee_kind) {
		case ERX_MF_GRANTEE_DOMAIN:
			grantee = enif_make_uint(env, facet->grantee);
			break;
		case ERX_MF_GRANTEE_SESSION:
			grantee = enif_make_tuple2(env, atom(env, "template"), enif_make_uint(env, facet->grantee));
			break;
		case ERX_MF_GRANTEE_SYSTEM:
			grantee = atom(env, "system");
			break;
		default:
			return (false);
		}
		server = service->server == ERX_MF_NONE ? atom(env, "system") : enif_make_uint(env, service->server);
		name = enif_make_atom_len(env, service->name, service->name_len);
		*grants = enif_make_list_cell(env, enif_make_tuple4(env, grantee, name, server, limits), *grants);
	}
	return (true);
}

/*
 * What the domain service reads of the manifest's configured domains:
 * {ok, #{host => Host, domains => Rows, services => Services, grants =>
 * Grants}}, Rows in row order, each #{row, place, name, principal, kind,
 * restarts, restart_period_s, boot_timeout_s}, place its place in the boot
 * order, and Services and Grants as served_terms makes them. The view is
 * fixed at boot, so this reads it without the lock.
 */
static ERL_NIF_TERM
configured_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM keys[8], values[8], row, rows, host, services, grants, result;
	const erx_dom_configured_t *configured;
	unsigned char *bytes;
	uint32_t index;

	(void)argv;
	if (argc != 0)
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	rows = enif_make_list(env, 0);
	/* Built from the last row back, so the list's head is row 0. */
	for (index = lib->view.nconfigured; index-- > 0;) {
		configured = &lib->view.configured[index];
		bytes = enif_make_new_binary(env, configured->name_len, &values[1]);
		if (bytes == NULL)
			return (enif_make_badarg(env));
		memcpy(bytes, configured->name, configured->name_len);
		keys[0] = atom(env, "row"), values[0] = enif_make_uint(env, index);
		keys[1] = atom(env, "name");
		keys[2] = atom(env, "principal"), values[2] = enif_make_uint(env, configured->principal);
		keys[3] = atom(env, "kind"),
		    values[3] = atom(env, configured->kind == ERX_MF_SECRET ? "secret" : "service");
		keys[4] = atom(env, "restarts"), values[4] = enif_make_uint(env, configured->restarts);
		keys[5] = atom(env, "restart_period_s"), values[5] = enif_make_uint(env, configured->restart_period_s);
		keys[6] = atom(env, "place"), values[6] = enif_make_uint(env, configured->place);
		keys[7] = atom(env, "boot_timeout_s"), values[7] = enif_make_uint(env, configured->boot_timeout_s);
		if (!enif_make_map_from_arrays(env, keys, values, 8, &row))
			return (enif_make_badarg(env));
		rows = enif_make_list_cell(env, row, rows);
	}
	bytes = enif_make_new_binary(env, lib->host_len, &host);
	if (bytes == NULL)
		return (enif_make_badarg(env));
	memcpy(bytes, lib->host, lib->host_len);
	if (!served_terms(env, &services, &grants))
		return (enif_make_badarg(env));
	keys[0] = atom(env, "host"), values[0] = host;
	keys[1] = atom(env, "domains"), values[1] = rows;
	keys[2] = atom(env, "services"), values[2] = services;
	keys[3] = atom(env, "grants"), values[3] = grants;
	if (!enif_make_map_from_arrays(env, keys, values, 4, &result))
		return (enif_make_badarg(env));
	return (enif_make_tuple2(env, atom(env, "ok"), result));
}

/*
 * The device catalogue with its holders (docs/design-system.md,
 * "Devices"): {ok, Devices} in catalogue order, each #{index, unit, row,
 * role, holder}. index is the entry's manifest device row; unit its unit
 * row; row the configured row its unit is placed on, or system; role its
 * record's role word, or none for a kind no runtime drives; holder the
 * living domain a creation gave it to, system for the system domain's
 * devices, or none. Role words come from erx/device_kinds.h, never from a
 * caller. A creation and an end change the holders, so this reads them
 * under the lock.
 */
static ERL_NIF_TERM
devices_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM keys[5], values[5], row, rows;
	const erx_dom_device_entry_t *entry;
	uint32_t index, holder;

	(void)argv;
	if (argc != 0)
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	rows = enif_make_list(env, 0);
	enif_mutex_lock(lib_lock);
	/* Built from the last entry back, so the list's head is entry 0. */
	for (index = lib->view.ndevices; index-- > 0;) {
		entry = &lib->view.devices[index];
		holder = lib->device_records[index].holder;
		keys[0] = atom(env, "index"), values[0] = enif_make_uint(env, index);
		keys[1] = atom(env, "unit"), values[1] = enif_make_uint(env, entry->unit);
		keys[2] = atom(env, "row"), values[2] = entry->row == ERX_MF_NONE ?
		    atom(env, "system") : enif_make_uint(env, entry->row);
		keys[3] = atom(env, "role"),
		    values[3] = atom(env, entry->role_word == NULL ? "none" : entry->role_word);
		keys[4] = atom(env, "holder"), values[4] = entry->row == ERX_MF_NONE ? atom(env, "system") :
		    holder == 0 ? atom(env, "none") : enif_make_uint(env, holder);
		if (!enif_make_map_from_arrays(env, keys, values, 5, &row)) {
			enif_mutex_unlock(lib_lock);
			return (enif_make_badarg(env));
		}
		rows = enif_make_list_cell(env, row, rows);
	}
	enif_mutex_unlock(lib_lock);
	return (enif_make_tuple2(env, atom(env, "ok"), rows));
}

/*
 * The manifest's session templates (property 14 of docs/design-system.md):
 * {ok, Templates} in principal order, one per principal, each
 * #{template, principal}, template its index among them. The boot creates
 * none of them. The view is fixed at boot, so this reads it without the
 * lock.
 */
static ERL_NIF_TERM
templates_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM keys[2], values[2], row, rows;
	uint32_t index;

	(void)argv;
	if (argc != 0)
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	rows = enif_make_list(env, 0);
	/* Built from the last template back, so the list's head is template 0. */
	for (index = lib->view.ntemplates; index-- > 0;) {
		keys[0] = atom(env, "template"), values[0] = enif_make_uint(env, index);
		keys[1] = atom(env, "principal"), values[1] = enif_make_uint(env, lib->view.templates[index].principal);
		if (!enif_make_map_from_arrays(env, keys, values, 2, &row))
			return (enif_make_badarg(env));
		rows = enif_make_list_cell(env, row, rows);
	}
	return (enif_make_tuple2(env, atom(env, "ok"), rows));
}

/*
 * Manifest startup and restart: creates configured row Row under id Id
 * (erx_dom_lib_configured). Only the domain service may, as for every
 * entry that changes the library, so a row is built only from one
 * configured_nif named, never from a number a request carries.
 */
static ERL_NIF_TERM
configured_create_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_dom_created_t created;
	erx_dom_pid_t domain_pid;
	erx_status_t status;
	unsigned int id, row;

	if (argc != 3 || !enif_get_uint(env, argv[0], &id) || !enif_get_uint(env, argv[1], &row) ||
	    !domain_pid_from(env, argv[2], &domain_pid))
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	status = caller_is_service(env) ? erx_dom_lib_configured(lib, id, row, domain_pid, &created) : ERX_ERIGHTS;
	enif_mutex_unlock(lib_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (created_term(env, &created));
}

/*
 * A session's start: creates a session of template Template under id Id,
 * name Name and domain pid DomainPid (erx_dom_lib_session). Only the domain
 * service may, so a session is built only from a template the view holds,
 * whose index the library bounds, never from fields a request carries.
 */
static ERL_NIF_TERM
session_create_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_dom_created_t created;
	erx_dom_pid_t domain_pid;
	erx_status_t status;
	ErlNifBinary name;
	unsigned int id, template;

	if (argc != 4 || !enif_get_uint(env, argv[0], &id) || !enif_get_uint(env, argv[1], &template) ||
	    !enif_inspect_binary(env, argv[2], &name) || name.size == 0 || name.size > ERX_DOM_NAME_MAX ||
	    !domain_pid_from(env, argv[3], &domain_pid))
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	status = caller_is_service(env) ?
	    erx_dom_lib_session(lib, id, template, (const char *)name.data, (uint32_t)name.size, domain_pid, &created) :
	    ERX_ERIGHTS;
	enif_mutex_unlock(lib_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	return (created_term(env, &created));
}

static ERL_NIF_TERM
create_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	static erx_dom_spec_t spec;	/* under lib_lock: 2 KiB of strings stay off the stack */
	erx_runtime_limits_t limits;
	erx_dom_created_t created;
	erx_status_t status;
	uint32_t given;
	bool shaped;

	if (argc != 1)
		return (enif_make_badarg(env));
	enif_mutex_lock(lib_lock);
	shaped = spec_from(env, argv[0], &spec, &limits, &given);
	if (!shaped)
		status = ERX_EINVAL;
	else if (lib == NULL)
		status = ERX_ENOTSUP;
	else if (!caller_is_service(env))
		status = ERX_ERIGHTS;
	else
		status = erx_dom_lib_create(lib, &spec, &limits, given, &created);
	/* No copy of the request's strings stays past the call, as in the library's own buffers. */
	memset(&spec, 0, sizeof(spec));
	enif_mutex_unlock(lib_lock);
	if (!shaped)
		return (enif_make_badarg(env));
	if (status != ERX_OK)
		return (status_error(env, status));
	return (created_term(env, &created));
}

/* One id's entry under the lock: start, retire, disconnect. */
static ERL_NIF_TERM
id_entry(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[],
    erx_status_t (*entry)(erx_dom_lib_t *, uint32_t))
{
	unsigned int id;
	erx_status_t status;

	if (argc != 1 || !enif_get_uint(env, argv[0], &id))
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	status = caller_is_service(env) ? entry(lib, id) : ERX_ERIGHTS;
	enif_mutex_unlock(lib_lock);
	return (status_term(env, status));
}

static ERL_NIF_TERM
start_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	return (id_entry(env, argc, argv, erx_dom_lib_start));
}

static ERL_NIF_TERM
retire_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	return (id_entry(env, argc, argv, erx_dom_lib_retire));
}

/*
 * The object a crash area is copied into, ERX_CRASH_SIZE bytes on the
 * system domain's budget, made at the first read and mapped read-only for
 * the library's life; both under lib_lock. The source area is never mapped.
 */
static uint64_t crash_copy = ERX_CAP_NULL;
static const uint8_t *crash_view;

static erx_status_t
crash_copy_up(void)
{
	uint64_t mem, addr;
	erx_status_t status;

	if (crash_view != NULL)
		return (ERX_OK);
	status = erx_mem_create(ERX_CAP_NULL, ERX_CRASH_SIZE, 0, &mem);
	if (status != ERX_OK)
		return (status);
	status = erx_vm_reserve(ERX_CAP_SELF, 0, ERX_CRASH_SIZE, 0, &addr);
	if (status == ERX_OK) {
		status = erx_vm_map(ERX_CAP_SELF, addr, ERX_CRASH_SIZE, mem, 0, ERX_PROT_R);
		if (status != ERX_OK)
			(void)erx_vm_release(ERX_CAP_SELF, addr, ERX_CRASH_SIZE);
	}
	if (status != ERX_OK) {
		(void)erx_cap_close(mem);
		return (status);
	}
	crash_copy = mem;
	crash_view = (const uint8_t *)(uintptr_t)addr;
	return (ERX_OK);
}

static ERL_NIF_TERM
bytes_term(ErlNifEnv *env, const uint8_t *bytes, size_t len)
{
	ERL_NIF_TERM term;

	memcpy(enif_make_new_binary(env, len, &term), bytes, len);
	return (term);
}

/*
 * crash_nif(Id): ended domain Id's crash area, copied out and read
 * (erx_dom_lib_crash_copy, erx_dom_dump_read): {ok, Slogan, Dump,
 * Truncated}, the slogan and dump text as binaries the domain wrote,
 * still untrusted text. {error, ecorrupt} for a header that fails a check,
 * {error, einval} for a domain not ended or without an area. Only the
 * service may read, as the dump holds the domain's data.
 */
static ERL_NIF_TERM
crash_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	erx_dom_dump_t dump;
	ERL_NIF_TERM result = 0;
	unsigned int id;
	erx_status_t status;

	if (argc != 1 || !enif_get_uint(env, argv[0], &id))
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	status = caller_is_service(env) ? crash_copy_up() : ERX_ERIGHTS;
	if (status == ERX_OK)
		status = erx_dom_lib_crash_copy(lib, id, crash_copy);
	if (status == ERX_OK)
		status = erx_dom_dump_read(crash_view, ERX_CRASH_SIZE, &dump);
	if (status == ERX_OK)
		result = enif_make_tuple4(env, atom(env, "ok"), bytes_term(env, dump.slogan, dump.slogan_len),
		    bytes_term(env, dump.text, (size_t)dump.length), atom(env, dump.truncated ? "true" : "false"));
	enif_mutex_unlock(lib_lock);
	return (status == ERX_OK ? result : status_error(env, status));
}

/* One party's values of a connection, as a map. */
static ERL_NIF_TERM
party_term(ErlNifEnv *env, const erx_dom_party_t *party)
{
	ERL_NIF_TERM keys[4], values[4], result;

	keys[0] = atom(env, "side");
	values[0] = enif_make_uint64(env, party->side);
	keys[1] = atom(env, "peer_side");
	values[1] = enif_make_uint64(env, party->peer_side);
	keys[2] = atom(env, "peer_bell");
	values[2] = enif_make_uint64(env, party->peer_bell);
	keys[3] = atom(env, "label");
	values[3] = enif_make_uint(env, party->label);
	if (!enif_make_map_from_arrays(env, keys, values, 4, &result))
		return (enif_make_new_map(env));
	return (result);
}

/* connect(A, B, AReads, BReads): {ok, #{number, a, b}}, each party's values in its own table. */
static ERL_NIF_TERM
connect_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned int a, b, a_reads, b_reads;
	erx_dom_linked_t linked;
	erx_status_t status;
	ERL_NIF_TERM keys[3], values[3], result;

	if (argc != 4 || !enif_get_uint(env, argv[0], &a) || !enif_get_uint(env, argv[1], &b) ||
	    !enif_get_uint(env, argv[2], &a_reads) || !enif_get_uint(env, argv[3], &b_reads))
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	status = caller_is_service(env) ? erx_dom_lib_connect(lib, a, b, a_reads, b_reads, &linked) : ERX_ERIGHTS;
	enif_mutex_unlock(lib_lock);
	if (status != ERX_OK)
		return (status_error(env, status));
	keys[0] = atom(env, "number");
	values[0] = enif_make_uint(env, linked.number);
	keys[1] = atom(env, "a");
	values[1] = party_term(env, &linked.a);
	keys[2] = atom(env, "b");
	values[2] = party_term(env, &linked.b);
	if (!enif_make_map_from_arrays(env, keys, values, 3, &result))
		return (enif_make_badarg(env));
	return (enif_make_tuple2(env, atom(env, "ok"), result));
}

static ERL_NIF_TERM
disconnect_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	return (id_entry(env, argc, argv, erx_dom_lib_disconnect));
}

static ERL_NIF_TERM
stop_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	unsigned int id;
	ErlNifSInt64 halt;
	erx_status_t status;

	if (argc != 2 || !enif_get_uint(env, argv[0], &id) || !enif_get_int64(env, argv[1], &halt))
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	status = caller_is_service(env) ? erx_dom_lib_stop(lib, id, halt) : ERX_ERIGHTS;
	enif_mutex_unlock(lib_lock);
	return (status_term(env, status));
}

/*
 * register(): the caller hears of every end from now on and is the one
 * process that may change the library. While another registered process
 * lives, the answer is {error, ebusy}, so no process takes the domain
 * service's place; once that process is dead, its restart registers
 * again. Only the caller itself registers, never a pid it names. With no
 * library there is nothing to hear of or change, and the answer is
 * {error, enotsup}, which tells the domain service to run without one.
 */
static ERL_NIF_TERM
register_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifPid pid;
	bool taken;

	(void)argv;
	if (argc != 0 || enif_self(env, &pid) == NULL)
		return (enif_make_badarg(env));
	if (lib == NULL)
		return (status_error(env, ERX_ENOTSUP));
	enif_mutex_lock(lib_lock);
	taken = service_set && enif_compare_pids(&service, &pid) != 0 &&
	    enif_is_process_alive(env, &service);
	if (!taken) {
		service = pid;
		service_set = true;
	}
	enif_mutex_unlock(lib_lock);
	return (taken ? status_error(env, ERX_EBUSY) : atom(env, "ok"));
}

/* An end's kind as the message names it. */
static const char *
end_name(erx_dom_end_kind_t kind)
{
	switch (kind) {
	case ERX_DOM_END_HALT:		return ("halt");
	case ERX_DOM_END_CRASH:		return ("crash");
	case ERX_DOM_END_FAULT:		return ("fault");
	case ERX_DOM_END_STOPPED:	return ("stopped");
	case ERX_DOM_END_NONE:
	default:			return ("none");
	}
}

/* {domain_ended, Id, {Kind, Status}, Record}, Record the exit record's fields by name. */
static ERL_NIF_TERM
report_term(ErlNifEnv *env, const erx_dom_report_t *report)
{
	const erx_fault_t *const record = &report->record;
	ERL_NIF_TERM keys[7], values[7], fields;

	keys[0] = atom(env, "kind"), values[0] = enif_make_uint(env, (unsigned int)record->kind);
	keys[1] = atom(env, "cause"), values[1] = enif_make_uint(env, record->cause);
	keys[2] = atom(env, "addr"), values[2] = enif_make_uint64(env, record->addr);
	keys[3] = atom(env, "pc"), values[3] = enif_make_uint64(env, record->pc);
	keys[4] = atom(env, "thread"), values[4] = enif_make_uint64(env, record->thread);
	keys[5] = atom(env, "space"), values[5] = enif_make_uint64(env, record->space);
	keys[6] = atom(env, "status"), values[6] = enif_make_int64(env, record->status);
	if (!enif_make_map_from_arrays(env, keys, values, 7, &fields))
		fields = enif_make_new_map(env);
	return (enif_make_tuple4(env, atom(env, "domain_ended"), enif_make_uint(env, report->id),
	    enif_make_tuple2(env, atom(env, end_name(report->end.kind)),
	    enif_make_int64(env, report->end.status)),
	    fields));
}

/*
 * How load learns that the fault thread's bind is done: the thread sets
 * status and clears binding under lib_lock, signals up, and touches the
 * struct no more, so load may destroy up once it sees binding clear.
 */
typedef struct fault_start {
	ErlNifCond	*up;
	bool		 binding;	/* under lib_lock */
	erx_status_t	 status;	/* under lib_lock, once binding is false */
} fault_start_t;

/*
 * The fault thread: binds the gate to itself, then for ever takes a record,
 * hands it to the library under the lock, and reports an end to the
 * registered process. A refused take (a message that is not a record) is
 * dropped: only the kernel posts to the gate.
 */
static void *
fault_main(void *arg)
{
	fault_start_t *const start = arg;
	ErlNifEnv *const env = enif_alloc_env();
	erx_dom_report_t report;
	erx_fault_t record;
	uint64_t label;
	ErlNifPid to;
	erx_status_t status;
	bool ended, heard;

	enif_mutex_lock(lib_lock);
	status = env == NULL ? ERX_ENOMEM : erx_gate_bind(lib->held.gate, ERX_CAP_SELF_THREAD, 0);
	start->status = status;
	start->binding = false;
	enif_cond_signal(start->up);
	enif_mutex_unlock(lib_lock);
	if (status != ERX_OK) {
		if (env != NULL)
			enif_free_env(env);
		return (NULL);
	}
	for (;;) {
		status = erx_dom_lib_take(ERX_WAIT_FOREVER, &label, &record);
		/*
		 * A message that is not a record is dropped; any other
		 * refusal ends the thread rather than spin (TODO.md).
		 */
		if (status == ERX_EINVAL)
			continue;
		if (status != ERX_OK)
			break;
		enif_mutex_lock(lib_lock);
		ended = erx_dom_lib_record(lib, label, &record, &report);
		heard = service_set;
		to = service;
		enif_mutex_unlock(lib_lock);
		if (!ended || !heard)
			continue;
		/* A dead receiver loses the report (TODO.md, the domain library's lost ends). */
		(void)enif_send(NULL, &to, env, report_term(env, &report));
		enif_clear_env(env);
	}
	enif_free_env(env);
	return (NULL);
}

/*
 * Starts the fault thread and waits until its bind is done: ERX_OK with the
 * thread running, or the refusal with no thread left behind.
 */
static erx_status_t
fault_thread_start(void)
{
	fault_start_t start = { .up = enif_cond_create("erx_domain_fault_up"), .binding = true };
	ErlNifTid tid;
	erx_status_t status;

	if (start.up == NULL)
		return (ERX_ENOMEM);
	if (enif_thread_create("erx_domain_fault", &tid, fault_main, &start, NULL) != 0) {
		status = ERX_ENOMEM;
	} else {
		enif_mutex_lock(lib_lock);
		while (start.binding)
			enif_cond_wait(start.up, lib_lock);
		status = start.status;
		enif_mutex_unlock(lib_lock);
		if (status != ERX_OK)
			(void)enif_thread_join(tid, NULL);
	}
	enif_cond_destroy(start.up);
	return (status);
}

/*
 * The library, its lock and its fault thread live as long as the system
 * domain, so only the first load sets them up and a later one (after a
 * purge) is refused. A library with no fault thread would never end a
 * domain, so then the module does not load and nothing is left behind.
 */
static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
	(void)env, (void)priv, (void)info;
	if (lib_lock != NULL)
		return (1);
	lib_lock = enif_mutex_create("erx_domain_lib");
	if (lib_lock == NULL)
		return (1);
	lib = erx_dom_lib_system();
	if (lib == NULL)
		return (0);
	if (fault_thread_start() == ERX_OK)
		return (0);
	lib = NULL;
	enif_mutex_destroy(lib_lock);
	lib_lock = NULL;
	return (1);
}

static ErlNifFunc nif_funcs[] = {
	/* register takes the lock a create holds across backend calls, so it is dirty too. */
	{ "register_nif", 0, register_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "create_nif", 1, create_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "start_nif", 1, start_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "stop_nif", 2, stop_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "retire_nif", 1, retire_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "crash_nif", 1, crash_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "connect_nif", 4, connect_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "disconnect_nif", 1, disconnect_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "configured_nif", 0, configured_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "templates_nif", 0, templates_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "devices_nif", 0, devices_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "configured_create_nif", 3, configured_create_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
	{ "session_create_nif", 4, session_create_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND },
};

ERL_NIF_INIT(erx_domain_lib, nif_funcs, load, NULL, NULL, NULL)
