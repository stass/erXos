/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_info_build, erx_boot_info_read, the vector made from a page, and
 * erx_boot_args_parse, each at its limits and against an independent statement of what
 * it should do. Prints one line and exits 0, or names what broke and exits 1.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/fiasco/boot_args.h"

#define CHECK(condition, ...) do {					\
	if (!(condition)) {						\
		fprintf(stderr, __VA_ARGS__);				\
		fputc('\n', stderr);					\
		exit(1);						\
	}								\
} while (0)
#define WORDS(literal)	{ (literal), sizeof(literal) - 1 }
#define COUNT(array)	(sizeof(array) / sizeof((array)[0]))

static _Alignas(ERX_PAGE_SIZE) uint8_t page[ERX_PAGE_SIZE];
static char big[ERX_PAGE_SIZE * 2];

static const erx_boot_words_t good_args[] = { WORDS("-S\0" "2:2\0" "--\0"), WORDS("-boot"), WORDS("/bin/start\0") };
static const erx_boot_words_t good_env[] = { WORDS("A=1\0" "B=\0") };

static erx_boot_inputs_t
good_inputs(void)
{
	return ((erx_boot_inputs_t){ .domain_id = 4, .flags = ERX_BOOT_ROOT, .pack_flags = 7, .group = { .raw = ERX_CAP_SELF },
	    .release_addr = 0x1000, .cpuset = 0xf, .capacity_mcpu = 4000, .node = "system@host", .node_len = 11,
	    .args = good_args, .nargs = COUNT(good_args), .env = good_env, .nenv = COUNT(good_env),
	    .limits = { .max_frame = 9 } });
}

static void
test_round_trip(void)
{
	erx_boot_inputs_t inputs = good_inputs();
	erx_boot_view_t view;

	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "a good page is refused");
	CHECK(erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_OK, "a page the builder wrote is refused");
	CHECK(view.info.version == ERX_BOOT_VERSION && view.info.abi_version == ERX_ABI_VERSION, "versions");
	CHECK(view.info.domain_id == 4 && view.info.flags == ERX_BOOT_ROOT && view.info.pack_flags == 7, "header fields");
	CHECK(view.info.group.raw == ERX_CAP_SELF && view.info.budget.raw == ERX_CAP_NULL && view.info.release_addr == 0x1000, "capabilities");
	CHECK(view.info.seal_addr == 0 && view.info.hwcap == 0 && view.info.hwcap2 == 0, "zero fields");
	CHECK(view.info.cpuset == 0xf && view.info.capacity_mcpu == 4000 && view.info.limits.max_frame == 9, "cpus and limits");
	CHECK(view.info.node_off == ERX_BOOT_INFO_SIZE + ERX_BOOT_ROOT_EXTENSION_SIZE, "strings lie past the root extension");
	CHECK(view.info.node_len == 11 && memcmp(view.node, "system@host", 11) == 0, "node");
	CHECK(view.info.args_len == 27 && memcmp(view.args, "-S\0" "2:2\0" "--\0" "-boot\0" "/bin/start\0", 27) == 0, "args");
	CHECK(view.info.env_len == 7 && memcmp(view.env, "A=1\0" "B=\0", 7) == 0, "env");

	inputs.flags = 0;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "a child page is refused");
	CHECK(erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_OK && view.info.node_off == ERX_BOOT_INFO_SIZE,
	    "a child's strings follow the fixed part");

	/* A domain's page names its system connection's peer, between its node and its args. */
	inputs.node = "web@host";
	inputs.node_len = 8;
	inputs.system_node = "system@host";
	inputs.system_node_len = 11;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "a domain's page is refused");
	CHECK(erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_OK, "a domain's page does not read back");
	CHECK(view.info.system_connection.peer_node_len == 11 &&
	    memcmp(page + view.info.system_connection.peer_node_off, "system@host", 11) == 0, "system node");
	CHECK(view.info.node_len == 8 && memcmp(view.node, "web@host", 8) == 0, "system node: the node moved");
	CHECK(view.info.args_len == 27 && memcmp(view.args, "-S\0" "2:2\0" "--\0" "-boot\0" "/bin/start\0", 27) == 0,
	    "system node: the args moved");
	inputs.system_node = "system";
	inputs.system_node_len = 6;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_NODE, "system node: a name without a host is accepted");
}

static void
test_strings_limit(void)
{
	erx_boot_inputs_t inputs = good_inputs();
	erx_boot_words_t word = { big, ERX_BOOT_STRINGS_MAX - 11 - 1 };
	erx_boot_view_t view;

	memset(big, 'x', sizeof(big));
	inputs.args = &word;
	inputs.nargs = 1;
	inputs.nenv = 0;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "strings limit: exactly the limit is refused");
	CHECK(erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_OK, "strings limit: the reader refuses the limit");
	word.length++;
	memset(page, 0xa5, sizeof(page));
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_STRINGS, "strings limit: one past it is accepted");
	word.length = SIZE_MAX;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_STRINGS, "strings limit: a huge length is accepted");
	inputs.nargs = 0;
	inputs.node_len = SIZE_MAX;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_STRINGS, "strings limit: a huge node is accepted");
	for (size_t at = 0; at < sizeof(page); at++)
		CHECK(page[at] == 0xa5, "a refused build left the page untouched: byte %zu moved", at);
}

static void
test_too_small(void)
{
	erx_boot_inputs_t inputs = good_inputs();
	const size_t need = ERX_BOOT_INFO_SIZE + ERX_BOOT_ROOT_EXTENSION_SIZE + 11 + 27 + 7;
	erx_boot_view_t view;

	for (size_t size = 0; size < need; size++) {
		memset(page, 0xa5, sizeof(page));
		CHECK(erx_boot_info_build(&inputs, page, size) == ERX_BOOT_INFO_TOO_SMALL, "a page of %zu bytes is accepted", size);
		CHECK(page[0] == 0xa5, "a refused build left the page untouched: size %zu", size);
	}
	CHECK(erx_boot_info_build(&inputs, page, need) == ERX_BOOT_INFO_OK, "the exact size is refused");
	for (size_t size = 0; size <= need; size++) {
		uint8_t *copy = malloc(size == 0 ? 1 : size);

		CHECK(copy != NULL, "no memory");
		memcpy(copy, page, size);
		const erx_boot_info_status_t status = erx_boot_info_read(copy, size, &view);

		CHECK((status == ERX_BOOT_INFO_OK) == (size == need), "a truncated page of %zu bytes reads as %d", size, status);
		free(copy);
	}
}

static void
test_words(void)
{
	static const struct {
		const char			*name;
		erx_boot_words_t		 part;
		erx_boot_info_status_t		 args, env;
	} cases[] = {
		{ "nothing", { NULL, 0 }, ERX_BOOT_INFO_OK, ERX_BOOT_INFO_OK },
		{ "one word", WORDS("a=b"), ERX_BOOT_INFO_OK, ERX_BOOT_INFO_OK },
		{ "one ended word", WORDS("a=b\0"), ERX_BOOT_INFO_OK, ERX_BOOT_INFO_OK },
		{ "two words", WORDS("a=1\0" "b=2"), ERX_BOOT_INFO_OK, ERX_BOOT_INFO_OK },
		{ "an empty word", WORDS("\0"), ERX_BOOT_INFO_WORDS, ERX_BOOT_INFO_WORDS },
		{ "one in the middle", WORDS("a=1\0\0" "b=2"), ERX_BOOT_INFO_WORDS, ERX_BOOT_INFO_WORDS },
		{ "two at the end", WORDS("a=1\0\0"), ERX_BOOT_INFO_WORDS, ERX_BOOT_INFO_WORDS },
		{ "no equals sign", WORDS("ab"), ERX_BOOT_INFO_OK, ERX_BOOT_INFO_ENV },
		{ "no key", WORDS("=b"), ERX_BOOT_INFO_OK, ERX_BOOT_INFO_ENV },
	};

	for (size_t at = 0; at < COUNT(cases); at++) {
		erx_boot_inputs_t inputs = good_inputs();
		erx_boot_info_status_t status;

		inputs.args = &cases[at].part;
		inputs.nargs = 1;
		status = erx_boot_info_build(&inputs, page, sizeof(page));
		CHECK(status == cases[at].args, "word list %s as args: %d", cases[at].name, status);
		inputs.args = good_args;
		inputs.nargs = COUNT(good_args);
		inputs.env = &cases[at].part;
		inputs.nenv = 1;
		status = erx_boot_info_build(&inputs, page, sizeof(page));
		CHECK(status == cases[at].env, "word list %s as env: %d", cases[at].name, status);
	}
}

static void
test_nodes_and_flags(void)
{
	static const struct {
		const char	*node;
		size_t		 length;
		bool		 good;
	} nodes[] = {
		{ "a@b", 3, true }, { "", 0, false }, { "ab", 2, false }, { "@b", 2, false }, { "a@", 2, false },
		{ "a@b@c", 5, false }, { "a\0@b", 4, false },
	};
	const uint32_t known = ERX_BOOT_DET | ERX_BOOT_INSTALLED_ONLY | ERX_BOOT_ROOT;

	for (size_t at = 0; at < COUNT(nodes); at++) {
		erx_boot_inputs_t inputs = good_inputs();

		inputs.node = nodes[at].node;
		inputs.node_len = nodes[at].length;
		CHECK((erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK) == nodes[at].good, "node %zu", at);
	}
	for (uint32_t flags = 0; flags < 256; flags++) {
		erx_boot_inputs_t inputs = good_inputs();
		erx_boot_view_t view;
		erx_boot_info_t info;

		inputs.flags = flags;
		CHECK((erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK) == ((flags & ~known) == 0), "build flags %u", flags);
		inputs.flags = ERX_BOOT_ROOT;
		CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "the root page");
		memcpy(&info, page, sizeof(info));
		info.flags = flags | ERX_BOOT_ROOT;
		memcpy(page, &info, sizeof(info));
		CHECK((erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_OK) == ((flags & ~known) == 0), "read flags %u", flags);
	}
}

/* One value of a corrupted field, by what the page's own words should make of it. */
static void
test_spans(void)
{
	const uint32_t fixed = ERX_BOOT_INFO_SIZE + ERX_BOOT_ROOT_EXTENSION_SIZE;
	const uint32_t size = ERX_PAGE_SIZE;
	const uint32_t offs[] = { 0, fixed - 1, fixed, size - 1, size, size + 1, UINT32_MAX };
	const uint32_t lens[] = { 0, 1, 2, 47, 2047, 2048, 2049, UINT32_MAX };
	const size_t fields[][2] = {
		{ ERX_BOOT_INFO_OFF_NODE_OFF, ERX_BOOT_INFO_OFF_NODE_LEN },
		{ ERX_BOOT_INFO_OFF_ARGS_OFF, ERX_BOOT_INFO_OFF_ARGS_LEN },
		{ ERX_BOOT_INFO_OFF_ENV_OFF, ERX_BOOT_INFO_OFF_ENV_LEN },
		{ ERX_BOOT_INFO_OFF_SYSTEM_CONNECTION + ERX_BOOT_CONNECTION_OFF_PEER_NODE_OFF,
		  ERX_BOOT_INFO_OFF_SYSTEM_CONNECTION + ERX_BOOT_CONNECTION_OFF_PEER_NODE_LEN },
	};
	erx_boot_inputs_t inputs = good_inputs();

	for (size_t f = 0; f < COUNT(fields); f++) {
		for (size_t o = 0; o < COUNT(offs); o++) {
			for (size_t l = 0; l < COUNT(lens); l++) {
				erx_boot_info_t info;
				erx_boot_view_t view;
				uint64_t total;
				bool inside;

				CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "the page");
				memcpy(page + fields[f][0], &offs[o], sizeof(uint32_t));
				memcpy(page + fields[f][1], &lens[l], sizeof(uint32_t));
				memcpy(&info, page, sizeof(info));
				total = (uint64_t)info.node_len + info.system_connection.peer_node_len + info.args_len + info.env_len;
				inside = lens[l] == 0 || (offs[o] >= fixed && offs[o] <= size && lens[l] <= size - offs[o]);

				const erx_boot_info_status_t status = erx_boot_info_read(page, sizeof(page), &view);

				if (total > ERX_BOOT_STRINGS_MAX)
					CHECK(status == ERX_BOOT_INFO_STRINGS, "field %zu off %u len %u: %d, not the strings limit", f, offs[o], lens[l], status);
				else if (!inside)
					CHECK(status == ERX_BOOT_INFO_BOUNDS, "bounds: field %zu off %u len %u reads as %d", f, offs[o], lens[l], status);
				else
					CHECK(status != ERX_BOOT_INFO_BOUNDS, "bounds: field %zu off %u len %u refused inside", f, offs[o], lens[l]);
			}
		}
	}
}

static void
test_header_corruption(void)
{
	const struct {
		size_t			offset;
		erx_boot_info_status_t	status;
	} cases[] = {
		{ ERX_BOOT_INFO_OFF_VERSION, ERX_BOOT_INFO_VERSION },
		{ ERX_BOOT_INFO_OFF_ABI_VERSION, ERX_BOOT_INFO_ABI_VERSION },
		{ ERX_BOOT_INFO_OFF_PACK_FLAGS + 4, ERX_BOOT_INFO_RESERVED },
		{ ERX_BOOT_INFO_OFF_ENV_LEN + 4, ERX_BOOT_INFO_RESERVED },
	};
	erx_boot_inputs_t inputs = good_inputs();
	erx_boot_view_t view;

	for (size_t at = 0; at < COUNT(cases); at++) {
		CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "the page");
		page[cases[at].offset] ^= 0x40;
		CHECK(erx_boot_info_read(page, sizeof(page), &view) == cases[at].status, "header offset %zu", cases[at].offset);
	}
	inputs.limits.reserved = 1;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_RESERVED, "limits' reserved word in a build");
	inputs.limits.reserved = 0;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "the page");
	page[ERX_BOOT_INFO_OFF_LIMITS + ERX_RUNTIME_LIMITS_OFF_RESERVED] = 1;
	CHECK(erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_RESERVED, "limits' reserved word in a read");
}

static void
check_vector(const char *node, size_t node_len, const char *flag)
{
	erx_boot_inputs_t inputs = good_inputs();
	const char *const words[] = { "beam", "-S", "2:2", "--", "-boot", "/bin/start", flag, node };
	erx_boot_view_t view;
	erx_boot_argv_plan_t plan;
	char **argv;
	char *strings;

	inputs.node = node;
	inputs.node_len = node_len;
	CHECK(erx_boot_info_build(&inputs, page, sizeof(page)) == ERX_BOOT_INFO_OK, "the page");
	CHECK(erx_boot_info_read(page, sizeof(page), &view) == ERX_BOOT_INFO_OK, "the view");
	plan = erx_boot_argv_plan(&view);
	CHECK(plan.argc == COUNT(words), "argc is %zu", plan.argc);
	argv = malloc((plan.argc + 1) * sizeof(*argv));
	strings = malloc(plan.strings);
	CHECK(argv != NULL && strings != NULL, "no memory");
	erx_boot_argv_fill(&view, argv, strings);
	for (size_t at = 0; at < plan.argc; at++) {
		CHECK(strcmp(argv[at], words[at]) == 0, "argv[%zu] is %s", at, argv[at]);
		CHECK(argv[at] >= strings && argv[at] < strings + plan.strings, "argv[%zu] lies outside writable memory", at);
	}
	CHECK(argv[plan.argc] == NULL, "argv ends in NULL");
	free(argv);
	free(strings);
}

static void
check_args(const char *line, bool good, const char *refused, bool det, bool watchdog, uint32_t count)
{
	const size_t length = strlen(line);
	char *copy = malloc(length + 1);
	erx_boot_args_t out;
	size_t cursor = 0;
	const char *word;
	size_t word_len;
	uint32_t seen = 0, bytes = 0;

	CHECK(copy != NULL, "no memory");
	memcpy(copy, line, length);
	CHECK(erx_boot_args_parse(copy, length, &out) == good, "the line [%.60s] is %s", line, good ? "refused" : "accepted");
	if (good) {
		CHECK(out.det == det && out.have_watchdog == watchdog && out.arg_count == count, "the line [%.60s] reads wrong", line);
		while (erx_boot_args_next_arg(copy, length, &cursor, &word, &word_len)) {
			seen++;
			bytes += (uint32_t)word_len + 1;
		}
		CHECK(seen == out.arg_count && bytes == out.arg_bytes, "the line [%.60s] walks to %u words of %u", line, seen, bytes);
	} else {
		CHECK(strlen(refused) == out.refused_len && memcmp(out.refused, refused, out.refused_len) == 0,
		    "the line [%.60s] names [%.*s]", line, (int)out.refused_len, out.refused);
	}
	free(copy);
}

static void
test_command_line(void)
{
	const size_t head = strlen("erx.arg=");
	char *line = malloc(ERX_BOOT_STRINGS_MAX * 2 + 64);
	erx_boot_args_t out;

	CHECK(line != NULL, "no memory");
	check_args("", true, NULL, false, false, 0);
	check_args("   ", true, NULL, false, false, 0);
	check_args("console=ttyAMA0 quiet erxfoo", true, NULL, false, false, 0);
	check_args("erx.det=1", true, NULL, true, false, 0);
	check_args("erx.watchdog=1,5,60", true, NULL, false, true, 0);
	check_args("  erx.arg=-S   erx.arg=2:2 x erx.det=1 ", true, NULL, true, false, 2);
	check_args("erx.det=0", false, "erx.det", false, false, 0);
	check_args("erx.det=", false, "erx.det", false, false, 0);
	check_args("erx.det", false, "erx.det", false, false, 0);
	check_args("erx.det=11", false, "erx.det", false, false, 0);
	check_args("erx.watchdog=1,5", false, "erx.watchdog", false, false, 0);
	check_args("erx.arg=", false, "erx.arg", false, false, 0);
	check_args("erx.nothing=1", false, "erx.nothing", false, false, 0);
	check_args("erx.", false, "erx.", false, false, 0);
	check_args("erx.group_report=0", false, "erx.group_report", false, false, 0);
	check_args("erx.group_report=", false, "erx.group_report", false, false, 0);
	check_args("erx.group_report=11", false, "erx.group_report", false, false, 0);
	check_args("erx.hostlink=1", true, NULL, false, false, 0);
	check_args("erx.hostlink=0", false, "erx.hostlink", false, false, 0);
	check_args("erx.hostlink=", false, "erx.hostlink", false, false, 0);
	check_args("erx.hostlink", false, "erx.hostlink", false, false, 0);
	check_args("erx.hostlink=11", false, "erx.hostlink", false, false, 0);
	check_args("erx.hostlink=yes", false, "erx.hostlink", false, false, 0);
	check_args("erx.hostlinks=1", false, "erx.hostlinks", false, false, 0);
	CHECK(erx_boot_args_parse("erx.group_report=1", 18, &out) && out.group_report && !out.det,
	    "erx.group_report=1 does not turn the report on alone");
	CHECK(erx_boot_args_parse("erx.det=1", 9, &out) && !out.group_report, "erx.det=1 turns the group report on");
	CHECK(erx_boot_args_parse("erx.hostlink=1", 14, &out) && out.hostlink && !out.det && !out.group_report,
	    "erx.hostlink=1 does not ask for the host link alone");
	CHECK(erx_boot_args_parse("erx.det=1 erx.group_report=1", 28, &out) && !out.hostlink,
	    "a line without erx.hostlink=1 asks for the host link");

	memcpy(line, "erx.arg=", head);
	memset(line + head, 'x', ERX_BOOT_STRINGS_MAX - 1);
	line[head + ERX_BOOT_STRINGS_MAX - 1] = '\0';
	check_args(line, true, NULL, false, false, 1);
	line[head + ERX_BOOT_STRINGS_MAX - 1] = 'x';
	line[head + ERX_BOOT_STRINGS_MAX] = '\0';
	if (erx_boot_args_parse(line, head + ERX_BOOT_STRINGS_MAX, &out))
		CHECK(false, "erx.arg limit: a word past the strings is accepted");
	CHECK(!erx_boot_args_parse("erx.arg=a\0b", 11, &out), "erx.arg with a NUL inside is accepted");
	CHECK(erx_boot_args_parse("quiet", 5, &out), "a boot loader's word is refused");

	/* Every prefix of a line, at its exact length, so a reader past the end shows under ASan. */
	const char *const whole = "a erx.arg=-S erx.watchdog=1,5,60 erx.det=1 erx.group_report=1 erx.hostlink=1 b";
	for (size_t length = 0; length <= strlen(whole); length++) {
		char *copy = malloc(length == 0 ? 1 : length);

		CHECK(copy != NULL, "no memory");
		memcpy(copy, whole, length);
		(void)erx_boot_args_parse(copy, length, &out);
		free(copy);
	}
	free(line);
}

int
main(void)
{
	test_round_trip();
	test_strings_limit();
	test_too_small();
	test_words();
	test_nodes_and_flags();
	test_spans();
	test_header_corruption();
	check_vector("system@host", 11, "-sname");
	check_vector("system@host.example", 19, "-name");
	check_vector("a.b@host", 8, "-sname");
	test_command_line();
	for (int status = ERX_BOOT_INFO_OK; status <= ERX_BOOT_INFO_ENV; status++) {
		const char *reason = erx_boot_info_reason((erx_boot_info_status_t)status);

		CHECK(reason != NULL && reason[0] != '\0', "status %d has no reason", status);
	}
	puts("boot info: ok");
	return (0);
}
