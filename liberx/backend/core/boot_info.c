/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <string.h>

#include "liberx/backend/core/boot_info.h"

#define BOOT_FLAGS_KNOWN	(ERX_BOOT_DET | ERX_BOOT_INSTALLED_ONLY | ERX_BOOT_ROOT)
#define BOOT_PROGRAM		"beam"
#define BOOT_FLAG_DOTTED	"-name"
#define BOOT_FLAG_PLAIN		"-sname"

_Static_assert(ERX_CAP_NULL == 0, "a zeroed page holds null capabilities");

static size_t
fixed_size(uint32_t flags)
{
	return (ERX_BOOT_INFO_SIZE + ((flags & ERX_BOOT_ROOT) != 0 ? ERX_BOOT_ROOT_EXTENSION_SIZE : 0));
}

static bool
node_valid(const char *node, size_t length)
{
	const char *at;

	if (length == 0 || memchr(node, '\0', length) != NULL)
		return (false);
	at = memchr(node, '@', length);
	if (at == NULL || at == node || at == node + length - 1)
		return (false);
	return (memchr(at + 1, '@', length - (size_t)(at + 1 - node)) == NULL);
}

/*
 * Checks each word of a list. A last word with no NUL of its own ends at length: the builder
 * adds that NUL, and the reader has refused such a list before it gets here.
 */
static erx_boot_info_status_t
words_check(const char *bytes, size_t length, bool env)
{
	size_t used = 0;

	while (used < length) {
		const char *const start = bytes + used;
		const char *const end = memchr(start, '\0', length - used);
		const size_t word = end != NULL ? (size_t)(end - start) : length - used;

		if (word == 0)
			return (ERX_BOOT_INFO_WORDS);
		if (env) {
			const char *const equals = memchr(start, '=', word);

			if (equals == NULL || equals == start)
				return (ERX_BOOT_INFO_ENV);
		}
		used += word + 1;
	}
	return (ERX_BOOT_INFO_OK);
}

/* What a part takes on the page, its last word's NUL included. */
static size_t
part_size(const erx_boot_words_t *part)
{
	if (part->length == 0)
		return (0);
	return (part->length + (part->bytes[part->length - 1] != '\0' ? 1 : 0));
}

/* Checks a list of parts and adds its size to the running total of strings, which stays in bounds. */
static erx_boot_info_status_t
parts_plan(const erx_boot_words_t *parts, size_t count, bool env, size_t *total, size_t *size)
{
	*size = 0;
	for (size_t at = 0; at < count; at++) {
		erx_boot_info_status_t status;
		size_t need;

		if (parts[at].length > ERX_BOOT_STRINGS_MAX)
			return (ERX_BOOT_INFO_STRINGS);
		need = part_size(&parts[at]);
		if (need > ERX_BOOT_STRINGS_MAX - *total)
			return (ERX_BOOT_INFO_STRINGS);
		status = words_check(parts[at].bytes, parts[at].length, env);
		if (status != ERX_BOOT_INFO_OK)
			return (status);
		*total += need;
		*size += need;
	}
	return (ERX_BOOT_INFO_OK);
}

static char *
parts_copy(const erx_boot_words_t *parts, size_t count, char *out)
{
	for (size_t at = 0; at < count; at++) {
		const size_t need = part_size(&parts[at]);

		if (need != 0) {
			memcpy(out, parts[at].bytes, parts[at].length);
			out[need - 1] = '\0';
			out += need;
		}
	}
	return (out);
}

/* Validates the whole request, so a refusal has written nothing. */
static erx_boot_info_status_t
build_plan(const erx_boot_inputs_t *inputs, size_t *args_len, size_t *env_len, size_t *total)
{
	erx_boot_info_status_t status;

	if ((inputs->flags & ~(uint32_t)BOOT_FLAGS_KNOWN) != 0)
		return (ERX_BOOT_INFO_FLAGS);
	if (inputs->limits.reserved != 0)
		return (ERX_BOOT_INFO_RESERVED);
	if (inputs->node_len > ERX_BOOT_STRINGS_MAX)
		return (ERX_BOOT_INFO_STRINGS);
	if (!node_valid(inputs->node, inputs->node_len))
		return (ERX_BOOT_INFO_NODE);
	if (inputs->system_node_len > ERX_BOOT_STRINGS_MAX - inputs->node_len)
		return (ERX_BOOT_INFO_STRINGS);
	if (inputs->system_node_len != 0 && !node_valid(inputs->system_node, inputs->system_node_len))
		return (ERX_BOOT_INFO_NODE);
	*total = inputs->node_len + inputs->system_node_len;
	status = parts_plan(inputs->args, inputs->nargs, false, total, args_len);
	if (status != ERX_BOOT_INFO_OK)
		return (status);
	return (parts_plan(inputs->env, inputs->nenv, true, total, env_len));
}

erx_boot_info_status_t
erx_boot_info_build(const erx_boot_inputs_t *inputs, void *page, size_t size)
{
	const size_t fixed = fixed_size(inputs->flags);
	size_t args_len = 0, env_len = 0, total = 0;
	const erx_boot_info_status_t status = build_plan(inputs, &args_len, &env_len, &total);
	char *out;

	if (status != ERX_BOOT_INFO_OK)
		return (status);
	if (size < fixed || total > size - fixed)
		return (ERX_BOOT_INFO_TOO_SMALL);

	const size_t args_off = fixed + inputs->node_len + inputs->system_node_len;
	erx_boot_connection_t system = inputs->system_connection;
	erx_boot_info_t info;

	system.peer_node_off = inputs->system_node_len != 0 ? (uint32_t)(fixed + inputs->node_len) : 0;
	system.peer_node_len = (uint32_t)inputs->system_node_len;
	info = (erx_boot_info_t){
		.version = ERX_BOOT_VERSION,
		.abi_version = ERX_ABI_VERSION,
		.domain_id = inputs->domain_id,
		.flags = inputs->flags,
		.pack_flags = inputs->pack_flags,
		.budget = inputs->budget,
		.space = inputs->space,
		.group = inputs->group,
		.spaces_group = inputs->spaces_group,
		.time_page = inputs->time_page,
		.release = inputs->release,
		.crash_area = inputs->crash_area,
		.system_connection = system,
		.release_addr = inputs->release_addr,
		.cpuset = inputs->cpuset,
		.capacity_mcpu = inputs->capacity_mcpu,
		.node_off = (uint32_t)fixed,
		.node_len = (uint32_t)inputs->node_len,
		.args_off = (uint32_t)args_off,
		.args_len = (uint32_t)args_len,
		.env_off = (uint32_t)(args_off + args_len),
		.env_len = (uint32_t)env_len,
		.limits = inputs->limits,
	};

	memset(page, 0, size);
	memcpy(page, &info, sizeof(info));
	out = (char *)page + fixed;
	memcpy(out, inputs->node, inputs->node_len);
	out += inputs->node_len;
	if (inputs->system_node_len != 0)
		memcpy(out, inputs->system_node, inputs->system_node_len);
	out = parts_copy(inputs->args, inputs->nargs, out + inputs->system_node_len);
	(void)parts_copy(inputs->env, inputs->nenv, out);
	return (ERX_BOOT_INFO_OK);
}

/* A string of length zero names nothing, wherever its offset points. */
static bool
span_ok(uint32_t off, uint32_t len, size_t fixed, size_t size)
{
	return (len == 0 || (off >= fixed && off <= size && len <= size - off));
}

static bool
all_zero(const uint8_t *bytes, size_t length)
{
	for (size_t at = 0; at < length; at++) {
		if (bytes[at] != 0)
			return (false);
	}
	return (true);
}

/* A word list on the page ends in its last word's NUL. */
static erx_boot_info_status_t
list_check(const char *bytes, size_t length, bool env)
{
	if (length != 0 && bytes[length - 1] != '\0')
		return (ERX_BOOT_INFO_WORDS);
	return (words_check(bytes, length, env));
}

erx_boot_info_status_t
erx_boot_info_read(const void *page, size_t size, erx_boot_view_t *view)
{
	const char *const bytes = page;
	erx_boot_info_t *const info = &view->info;
	erx_boot_info_status_t status;
	size_t fixed;

	if (size < ERX_BOOT_INFO_SIZE)
		return (ERX_BOOT_INFO_TOO_SMALL);
	memcpy(info, page, sizeof(*info));
	if (info->version != ERX_BOOT_VERSION)
		return (ERX_BOOT_INFO_VERSION);
	if (info->abi_version != ERX_ABI_VERSION)
		return (ERX_BOOT_INFO_ABI_VERSION);
	if ((info->flags & ~(uint32_t)BOOT_FLAGS_KNOWN) != 0)
		return (ERX_BOOT_INFO_FLAGS);
	if (!all_zero(info->padding_0, sizeof(info->padding_0)) || !all_zero(info->padding_1, sizeof(info->padding_1)) ||
	     info->limits.reserved != 0)
		return (ERX_BOOT_INFO_RESERVED);
	fixed = fixed_size(info->flags);
	if (size < fixed)
		return (ERX_BOOT_INFO_TOO_SMALL);
	if ((uint64_t)info->node_len + info->system_connection.peer_node_len + info->args_len + info->env_len >
	    ERX_BOOT_STRINGS_MAX)
		return (ERX_BOOT_INFO_STRINGS);
	if (!span_ok(info->node_off, info->node_len, fixed, size) ||
	    !span_ok(info->system_connection.peer_node_off, info->system_connection.peer_node_len, fixed, size) ||
	    !span_ok(info->args_off, info->args_len, fixed, size) ||
	    !span_ok(info->env_off, info->env_len, fixed, size))
		return (ERX_BOOT_INFO_BOUNDS);

	view->node = bytes + (info->node_len != 0 ? info->node_off : 0);
	view->system_node = bytes + (info->system_connection.peer_node_len != 0 ? info->system_connection.peer_node_off : 0);
	view->args = bytes + (info->args_len != 0 ? info->args_off : 0);
	view->env = bytes + (info->env_len != 0 ? info->env_off : 0);
	if (!node_valid(view->node, info->node_len))
		return (ERX_BOOT_INFO_NODE);
	if (info->system_connection.peer_node_len != 0 &&
	    !node_valid(view->system_node, info->system_connection.peer_node_len))
		return (ERX_BOOT_INFO_NODE);
	status = list_check(view->args, info->args_len, false);
	if (status != ERX_BOOT_INFO_OK)
		return (status);
	return (list_check(view->env, info->env_len, true));
}

const char *
erx_boot_info_reason(erx_boot_info_status_t status)
{
	switch (status) {
	case ERX_BOOT_INFO_OK:
		return ("accepted");
	case ERX_BOOT_INFO_TOO_SMALL:
		return ("the page is too small");
	case ERX_BOOT_INFO_VERSION:
		return ("the page is of another version");
	case ERX_BOOT_INFO_ABI_VERSION:
		return ("the page is of another ABI");
	case ERX_BOOT_INFO_FLAGS:
		return ("an unknown flag");
	case ERX_BOOT_INFO_RESERVED:
		return ("a reserved word that is not zero");
	case ERX_BOOT_INFO_STRINGS:
		return ("more strings than the page's limit");
	case ERX_BOOT_INFO_BOUNDS:
		return ("a string outside the page");
	case ERX_BOOT_INFO_NODE:
		return ("a node name not of the form <name>@<host>");
	case ERX_BOOT_INFO_WORDS:
		return ("an empty word, or a list not ended by a NUL");
	case ERX_BOOT_INFO_ENV:
		return ("an environment word that is not KEY=VALUE");
	}
	return ("an unknown reason");
}

static const char *
node_flag(const erx_boot_view_t *view)
{
	const char *const at = memchr(view->node, '@', view->info.node_len);
	const size_t host = view->info.node_len - (size_t)(at + 1 - view->node);

	return (memchr(at + 1, '.', host) != NULL ? BOOT_FLAG_DOTTED : BOOT_FLAG_PLAIN);
}

erx_boot_argv_plan_t
erx_boot_argv_plan(const erx_boot_view_t *view)
{
	erx_boot_argv_plan_t plan = {
		.argc = 3,
		.strings = sizeof(BOOT_PROGRAM) + view->info.args_len + strlen(node_flag(view)) + 1 + view->info.node_len + 1,
	};

	for (uint32_t at = 0; at < view->info.args_len; at++) {
		if (view->args[at] == '\0')
			plan.argc++;
	}
	return (plan);
}

/* Copies a string, its NUL added, and returns where the next one goes. */
static char *
string_copy(char *out, const char *text, size_t length)
{
	memcpy(out, text, length);
	out[length] = '\0';
	return (out + length + 1);
}

void
erx_boot_argv_fill(const erx_boot_view_t *view, char **argv, char *strings)
{
	const char *const flag = node_flag(view);
	size_t argc = 0, used = 0;
	char *out = strings;

	argv[argc++] = out;
	out = string_copy(out, BOOT_PROGRAM, strlen(BOOT_PROGRAM));
	while (used < view->info.args_len) {
		const size_t word = strlen(view->args + used);

		argv[argc++] = out;
		out = string_copy(out, view->args + used, word);
		used += word + 1;
	}
	argv[argc++] = out;
	out = string_copy(out, flag, strlen(flag));
	argv[argc++] = out;
	(void)string_copy(out, view->node, view->info.node_len);
	argv[argc] = NULL;
}
