/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the scheduler core (kernel/sched/sched.c). It reads one
 * command per line from the file named by its argument and prints each
 * command's result; `state` prints everything the core decides from the
 * whole machine, which test/fixtures/sched_model.rb predicts independently.
 * The machine has CPUS CPUs, its mask MACHINE_CPUS. GRANT is eleven numbers: quota_ns period_ns
 * cpuset capacity_mcpu capacity_first slice_us grace_us base ceiling flags
 * padding.
 *
 *   machine CAP          a new machine whose flags are capped to CAP, whose
 *                        root is told of MACHINE_CPUS
 *   cpus MASK            the CPUs the next root is told of instead, to test
 *                        what a grant reads back; the model has no such
 *                        command, and the CPU records stay CPUS
 *   root GRANT           creates group 0
 *   group P GRANT        creates the next group under P
 *   configure G GRANT    replaces G's grant
 *   normalize GRANT      prints the normalized grant
 *   thread G             creates the next thread in G
 *   urgency T U          sets T's base
 *   affinity T MASK      sets T's affinity
 *   wake C T             wakes T on CPU C; prints whether C must pick
 *   refresh C T          resolves T again on CPU C; prints whether C must pick
 *   remove C T           takes T off C's queues; prints whether it did
 *   pick C WHY RAN       picks on CPU C; prints the decision
 *   place T IDLE         prints the CPU a wake of T goes to
 *   state                prints the whole state
 *   race SEED ITERATIONS replaces grants, bases and affinities on two
 *                        threads while CPUs 0 and 1 wake and pick on two
 *                        others, for ThreadSanitizer
 */

#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sched_impl.h"

#define CPUS		4
#define GROUPS_MAX	32
#define THREADS_MAX	64
#define WORDS_MAX	16
#define GRANT_WORDS	11
#define MACHINE_CPUS	((UINT64_C(1) << CPUS) - 1)
#define RACE_CPUS	2

static erx_sched_group_t	groups[GROUPS_MAX];
static erx_sched_thread_t	threads[THREADS_MAX];
static erx_sched_cpu_t		cpus[CPUS];
static uint64_t			root_cpus = MACHINE_CPUS;
static int			ngroups;
static int			nthreads;
static erx_group_flags_t	cap;

static void
die(const char *message)
{
	fprintf(stderr, "sched driver: %s\n", message);
	exit(2);
}

static erx_sched_group_t *
group_at(uint64_t id)
{
	if (id >= (uint64_t)ngroups)
		die("no such group");
	return (&groups[id]);
}

static erx_sched_thread_t *
thread_at(uint64_t id)
{
	if (id >= (uint64_t)nthreads)
		die("no such thread");
	return (&threads[id]);
}

static erx_sched_cpu_t *
cpu_at(uint64_t id)
{
	if (id >= CPUS)
		die("no such CPU");
	return (&cpus[id]);
}

static int
thread_id(const erx_sched_thread_t *thread)
{
	return ((int)(thread - threads));
}

static erx_grant_t
grant_of(const uint64_t *word)
{
	erx_grant_t grant;
	uint32_t padding = (uint32_t)word[10];

	memset(&grant, 0, sizeof(grant));
	grant.quota_ns = word[0];
	grant.period_ns = word[1];
	grant.cpuset = word[2];
	grant.capacity_mcpu = (uint32_t)word[3];
	grant.capacity_first = (uint32_t)word[4];
	grant.slice_us = (uint32_t)word[5];
	grant.grace_us = (uint32_t)word[6];
	grant.base.raw = (uint8_t)word[7];
	grant.ceiling.raw = (uint8_t)word[8];
	grant.flags = (erx_group_flags_t)word[9];
	memcpy(grant.padding_0, &padding, sizeof(padding));
	return (grant);
}

static void
print_grant(const erx_grant_t *grant)
{
	printf("%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%u,%u,%u,%u,%u,%u,%u",
	    grant->quota_ns, grant->period_ns, grant->cpuset,
	    grant->capacity_mcpu, grant->capacity_first, grant->slice_us,
	    grant->grace_us, grant->base.raw, grant->ceiling.raw, grant->flags);
}

/* Walks a level both ways and against its bit, so a broken link shows. */
static void
print_level(const erx_sched_cpu_t *cpu, int level)
{
	const sched_fifo_t *fifo = &cpu->levels[level];
	const erx_sched_thread_t *thread, *last = NULL;

	if (((cpu->ready >> level & 1) != 0) != (fifo->head != NULL))
		die("a level's bit disagrees with its list");
	if (fifo->head == NULL)
		return;
	printf(";%d=", level);
	for (thread = fifo->head; thread != NULL; thread = thread->next) {
		if (thread->prev != last || thread->urgency != level ||
		    thread->where != sched_where(SCHED_THREAD_READY, cpu->index))
			die("a queued thread's record disagrees with its list");
		printf("%s%d", last == NULL ? "" : "+", thread_id(thread));
		last = thread;
	}
	if (fifo->tail != last)
		die("a level's tail is not its last thread");
}

static void
print_state(void)
{
	static const char state_names[] = "orR";
	erx_grant_t grant;
	erx_sched_capacity_t capacity;
	int i, level;

	printf("S");
	for (i = 0; i < ngroups; i++) {
		erx_sched_group_grant(&groups[i], &grant);
		capacity = erx_sched_group_capacity(&groups[i]);
		printf(" g%d:%u,%u,%" PRIu64 ",%" PRIu64 ",%u,%u/", i,
		    erx_sched_group_ceiling(&groups[i]).raw,
		    erx_sched_group_base(&groups[i]).raw,
		    erx_sched_group_cpuset(&groups[i]),
		    erx_sched_group_slice_ns(&groups[i]),
		    capacity.mcpu, capacity.first);
		print_grant(&grant);
	}
	for (i = 0; i < nthreads; i++) {
		printf(" t%d:%u,%" PRIu64 ",%c,%" PRIu64 ",%u,%u,%" PRIu64 ",%u", i,
		    erx_sched_resolve(&threads[i]).raw,
		    erx_sched_thread_cpus(&threads[i]),
		    state_names[sched_where_state(threads[i].where)],
		    threads[i].slice_left_ns, threads[i].last_cpu,
		    erx_sched_thread_on_cpu(&threads[i]),
		    erx_sched_group_slice_ns(
		    erx_sched_thread_group(&threads[i])), threads[i].urgency);
	}
	for (i = 0; i < CPUS; i++) {
		if (cpus[i].running != NULL)
			printf(" c%d:%d,%" PRIx64, i,
			    thread_id(cpus[i].running), cpus[i].ready);
		else
			printf(" c%d:-,%" PRIx64, i, cpus[i].ready);
		for (level = 0; level < SCHED_LEVELS; level++)
			print_level(&cpus[i], level);
	}
	printf("\n");
}

static void
print_pick(const erx_sched_decision_t *decision)
{
	uint32_t i;

	if (decision->run != NULL)
		printf("= run=%d urgency=%u slice=%" PRIu64 " again=%d leaving=",
		    thread_id(decision->run), decision->urgency.raw,
		    decision->slice_ns, decision->again);
	else
		printf("= run=- urgency=0 slice=0 again=%d leaving=",
		    decision->again);
	for (i = 0; i < decision->nleaving; i++)
		printf("%s%d", i == 0 ? "" : "+", thread_id(decision->leaving[i]));
	printf("\n");
}

/* The race: what it shares, and its deterministic random source. */
typedef struct race_args {
	uint64_t	seed;
	uint64_t	iterations;
	int		who;
} race_args_t;

static uint64_t
race_next(uint64_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return (*state);
}

static void *
race_configure(void *argument)
{
	const race_args_t *args = argument;
	uint64_t state = args->seed | 1;
	uint64_t i;

	for (i = 0; i < args->iterations; i++) {
		uint64_t word[GRANT_WORDS] = { ERX_QUOTA_NONE, 10000000 };
		erx_grant_t grant;

		word[2] = race_next(&state) & 15;
		word[2] |= i % (uint64_t)ngroups == 0 ? 1 : 0;
		word[3] = 1000;
		word[5] = race_next(&state) % 100000;
		word[6] = 50;
		word[7] = race_next(&state) % 64;
		word[8] = race_next(&state) % 64;
		if (i % (uint64_t)ngroups == 0)
			word[8] = 31;
		grant = grant_of(word);
		if (erx_sched_group_configure(&groups[i % (uint64_t)ngroups],
		    &grant, cap) != ERX_OK)
			die("race: a valid grant was refused");
	}
	return (NULL);
}

static void *
race_thread_limits(void *argument)
{
	const race_args_t *args = argument;
	uint64_t state = (args->seed * 3) | 1;
	uint64_t i;

	for (i = 0; i < args->iterations; i++) {
		erx_sched_thread_t *thread = &threads[i % (uint64_t)nthreads];
		erx_urgency_t urgency;

		urgency.raw = (uint8_t)(race_next(&state) % 64);
		if (erx_sched_thread_set_urgency(thread, urgency) != ERX_OK)
			die("race: a valid urgency was refused");
		erx_sched_thread_set_affinity(thread, race_next(&state));
	}
	return (NULL);
}

/* One CPU's owner: it alone wakes and picks the threads of its own parity. */
static void *
race_cpu(void *argument)
{
	const race_args_t *args = argument;
	erx_sched_cpu_t *cpu = &cpus[args->who];
	uint64_t state = (args->seed * 5 + (uint64_t)args->who) | 1;
	uint64_t i, grant_cpuset;
	uint8_t root_ceiling;
	erx_sched_capacity_t capacity;
	erx_grant_t grant;
	erx_sched_decision_t decision;
	int t;

	root_ceiling = erx_sched_group_ceiling(&groups[0]).raw;
	for (i = 0; i < args->iterations; i++) {
		for (t = args->who; t < nthreads; t += RACE_CPUS)
			(void)erx_sched_wake(cpu, &threads[t]);
		erx_sched_pick(cpu, (erx_sched_why_t)(race_next(&state) % 4),
		    race_next(&state) % 1000000, &decision);
		if (decision.nleaving > ERX_PICK_MOVES)
			die("race: a pick moved past its bound");
		if (decision.urgency.raw > root_ceiling)
			die("race: a dispatch above the root's ceiling");
		for (t = 0; t < nthreads; t++) {
			uint64_t allowed = erx_sched_thread_cpus(&threads[t]);

			if (allowed == 0 || (allowed & ~MACHINE_CPUS) != 0)
				die("race: CPUs outside the machine's");
			if (erx_sched_place(&threads[t], race_next(&state)) >= CPUS)
				die("race: a placement on an absent CPU");
			if (erx_sched_resolve(&threads[t]).raw > root_ceiling)
				die("race: a resolve above the root's ceiling");
		}
		capacity = erx_sched_group_capacity(&groups[ngroups - 1]);
		erx_sched_group_grant(&groups[ngroups - 1], &grant);
		grant_cpuset = erx_sched_group_cpuset(&groups[ngroups - 1]);
		if (capacity.mcpu > CPUS * 1000 || capacity.first >= CPUS ||
		    grant_cpuset == 0 || grant.ceiling.raw > ERX_URGENCY_MAX)
			die("race: a group's limits out of range");
	}
	return (NULL);
}

static void
race(uint64_t seed, uint64_t iterations)
{
	void *(*bodies[])(void *) = { race_cpu, race_cpu, race_configure,
	    race_thread_limits };
	pthread_t workers[4];
	race_args_t args[4];
	int i;

	if (ngroups < 2 || nthreads < RACE_CPUS)
		die("race: needs a child group and two threads");
	for (i = 0; i < 4; i++) {
		args[i] = (race_args_t){ seed, iterations, i };
		if (pthread_create(&workers[i], NULL, bodies[i], &args[i]) != 0)
			die("race: pthread_create failed");
	}
	for (i = 0; i < 4; i++) {
		if (pthread_join(workers[i], NULL) != 0)
			die("race: pthread_join failed");
	}
}

static void
new_machine(uint64_t new_cap)
{
	uint32_t i;

	root_cpus = MACHINE_CPUS;
	ngroups = 0;
	nthreads = 0;
	cap = (erx_group_flags_t)new_cap;
	for (i = 0; i < CPUS; i++) {
		if (erx_sched_cpu_init(&cpus[i], i) != ERX_OK)
			die("a CPU within every cpuset was refused");
	}
}

static void
new_group(const uint64_t *parent, const uint64_t *word)
{
	erx_grant_t grant = grant_of(word);
	erx_status_t status;

	if (ngroups == GROUPS_MAX)
		die("too many groups");
	if (parent == NULL)
		status = erx_sched_root_init(&groups[ngroups], root_cpus, &grant,
		    cap);
	else
		status = erx_sched_group_init(&groups[ngroups],
		    group_at(*parent), &grant, cap);
	if (status == ERX_OK)
		ngroups++;
	printf("= %d\n", status);
}

/* Each command's operands, so that a short line cannot act on thread 0. */
static int
operands_of(const char *name)
{
	static const struct {
		const char	*name;
		int		 operands;
	} commands[] = {
		{ "machine", 1 }, { "cpus", 1 }, { "root", GRANT_WORDS },
		{ "group", GRANT_WORDS + 1 }, { "configure", GRANT_WORDS + 1 },
		{ "normalize", GRANT_WORDS }, { "thread", 1 }, { "urgency", 2 },
		{ "affinity", 2 }, { "wake", 2 }, { "refresh", 2 }, { "remove", 2 },
		{ "pick", 3 },
		{ "place", 2 }, { "state", 0 }, { "race", 2 }
	};
	size_t i;

	for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
		if (strcmp(name, commands[i].name) == 0)
			return (commands[i].operands);
	}
	die("unknown command");
	return (0);
}

static void
run_command(const char *name, const uint64_t *word, int nwords)
{
	erx_sched_decision_t decision;
	erx_grant_t grant;
	erx_urgency_t urgency;
	erx_status_t status;

	if (nwords != operands_of(name))
		die("wrong number of operands");
	if (strcmp(name, "machine") == 0) {
		new_machine(word[0]);
		printf("= 0\n");
	} else if (strcmp(name, "cpus") == 0) {
		root_cpus = word[0];
		printf("= 0\n");
	} else if (strcmp(name, "root") == 0) {
		new_group(NULL, word);
	} else if (strcmp(name, "group") == 0) {
		new_group(&word[0], &word[1]);
	} else if (strcmp(name, "configure") == 0) {
		grant = grant_of(&word[1]);
		printf("= %d\n", erx_sched_group_configure(group_at(word[0]),
		    &grant, cap));
	} else if (strcmp(name, "normalize") == 0) {
		erx_grant_t result;

		grant = grant_of(word);
		status = erx_grant_normalize(&grant, cap, &result);
		printf("= %d", status);
		if (status == ERX_OK) {
			printf(" ");
			print_grant(&result);
		}
		printf("\n");
	} else if (strcmp(name, "thread") == 0) {
		if (nthreads == THREADS_MAX)
			die("too many threads");
		erx_sched_thread_init(&threads[nthreads], group_at(word[0]));
		nthreads++;
		printf("= 0\n");
	} else if (strcmp(name, "urgency") == 0) {
		urgency.raw = (uint8_t)word[1];
		printf("= %d\n", erx_sched_thread_set_urgency(thread_at(word[0]),
		    urgency));
	} else if (strcmp(name, "affinity") == 0) {
		erx_sched_thread_set_affinity(thread_at(word[0]), word[1]);
		printf("= 0\n");
	} else if (strcmp(name, "wake") == 0) {
		printf("= %d\n", erx_sched_wake(cpu_at(word[0]),
		    thread_at(word[1])));
	} else if (strcmp(name, "refresh") == 0) {
		printf("= %d\n", erx_sched_refresh(cpu_at(word[0]),
		    thread_at(word[1])));
	} else if (strcmp(name, "remove") == 0) {
		printf("= %d\n", erx_sched_remove(cpu_at(word[0]),
		    thread_at(word[1])));
	} else if (strcmp(name, "pick") == 0) {
		erx_sched_pick(cpu_at(word[0]), (erx_sched_why_t)word[1],
		    word[2], &decision);
		print_pick(&decision);
	} else if (strcmp(name, "place") == 0) {
		printf("= %u\n", erx_sched_place(thread_at(word[0]), word[1]));
	} else if (strcmp(name, "state") == 0) {
		print_state();
	} else if (strcmp(name, "race") == 0) {
		race(word[0], word[1]);
		printf("= 0\n");
	} else {
		die("unknown command");
	}
}

int
main(int argc, char **argv)
{
	char line[512];
	FILE *input;

	if (argc != 2)
		die("usage: sched_driver SCRIPT");
	input = fopen(argv[1], "r");
	if (input == NULL)
		die("cannot open the script");
	while (fgets(line, sizeof(line), input) != NULL) {
		uint64_t word[WORDS_MAX] = {0};
		char *cursor = NULL;
		char *name = strtok_r(line, " \n", &cursor);
		char *token;
		int nwords = 0;

		if (name == NULL)
			continue;
		while ((token = strtok_r(NULL, " \n", &cursor)) != NULL) {
			if (nwords == WORDS_MAX)
				die("too many operands");
			errno = 0;
			word[nwords++] = strtoull(token, NULL, 0);
			if (errno != 0)
				die("an operand does not parse");
		}
		run_command(name, word, nwords);
	}
	fclose(input);
	return (0);
}
