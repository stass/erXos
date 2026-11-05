/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A C program linked against erXos's musl, run as the root on native Fiasco. It uses
 * nothing but the C library's interface, apart from the pool's page count that shows
 * stacks come back. Each case reports one line through stdio, and exit() ends the
 * machine, so a transcript that reaches its last line has run exit's whole path.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* Join and detached rounds: each deletion waits for a grace period across CPUs. */
#define CHURN_ROUNDS		1000
#define BROADCAST_WAITERS	64
#define BROADCAST_ROUNDS	20
#define WORKERS			8
#define MUTEX_ROUNDS		20000
#define MALLOC_ROUNDS		2000
#define MALLOC_SLOTS		64
#define MPROTECT_ROUNDS		200
#define TIMED_WAIT_NS		INT64_C(20000000)
#define NS_PER_SEC		INT64_C(1000000000)
#define RETRY_NS		1000000L
#define SETTLE_SECONDS		60

/* How many pages the backend's pool holds. */
uint64_t	erx_fiasco_vm_free_pages(void);

static int cpu_count;

static _Thread_local int tls_data = 7;
static _Thread_local int tls_zero;

static int64_t
now_ns(clockid_t clock)
{
	struct timespec time;

	clock_gettime(clock, &time);
	return ((int64_t)time.tv_sec * NS_PER_SEC + time.tv_nsec);
}

static void
pause_retry(void)
{
	const struct timespec wait = { 0, RETRY_NS };

	nanosleep(&wait, NULL);
}

static int
pin_to(pthread_t thread, int cpu)
{
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	return (pthread_setaffinity_np(thread, sizeof(set), &set));
}

/* A CPU that does not exist is refused, which is how a C program counts them here. */
static int
count_cpus(void)
{
	int count = 0;

	while (count < 64 && pin_to(pthread_self(), count) == 0)
		count++;
	return (pin_to(pthread_self(), 0) == 0 ? count : 0);
}

/* pthread_create, retried while the last threads' indices wait for the kernel. */
static int
create_retrying(pthread_t *thread, const pthread_attr_t *attr, void *(*entry)(void *), void *arg)
{
	int status;

	for (int attempt = 0; attempt < SETTLE_SECONDS * 1000; attempt++) {
		status = pthread_create(thread, attr, entry, arg);
		if (status != EAGAIN)
			return (status);
		pause_retry();
	}
	return (status);
}

/* Waits until the pool holds what it held, since a reaper frees after the thread ends. */
static int
pool_returns_to(uint64_t pages)
{
	for (int attempt = 0; attempt < SETTLE_SECONDS * 1000; attempt++) {
		if (erx_fiasco_vm_free_pages() >= pages)
			return (1);
		pause_retry();
	}
	return (0);
}

static int
case_printf_float(void)
{
	char text[64];
	volatile double value = 2.5;

	snprintf(text, sizeof(text), "%.3f %Lg %d %s", value * value, (long double)value, 42, "ok");
	return (strcmp(text, "6.250 2.5 42 ok") == 0);
}

/* A flag the seam does not offer is refused and leaves the mapping alone, a mapping with no type is invalid, and the listed hints are taken. */
static int
case_mmap_flags(void)
{
	const int anonymous = MAP_PRIVATE | MAP_ANONYMOUS;
	const size_t size = 4096;
	char *const page = mmap(NULL, size, PROT_READ | PROT_WRITE, anonymous, -1, 0);
	char *hinted;

	if (page == MAP_FAILED)
		return (0);
	*page = 7;
	errno = 0;
	if (mmap(page, size, PROT_READ | PROT_WRITE, anonymous | MAP_FIXED | MAP_FIXED_NOREPLACE, -1, 0) != MAP_FAILED ||
	    errno != EOPNOTSUPP || *page != 7)
		return (0);
	errno = 0;
	if (mmap(page, size, PROT_READ | PROT_WRITE, anonymous | MAP_FIXED_NOREPLACE, -1, 0) != MAP_FAILED ||
	    errno != EOPNOTSUPP)
		return (0);
	errno = 0;
	if (mmap(NULL, size, PROT_READ | PROT_WRITE, anonymous | MAP_POPULATE, -1, 0) != MAP_FAILED || errno != EOPNOTSUPP)
		return (0);
	errno = 0;
	if (mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS, -1, 0) != MAP_FAILED || errno != EINVAL)
		return (0);
	hinted = mmap(NULL, size, PROT_READ | PROT_WRITE, anonymous | MAP_NORESERVE | MAP_STACK, -1, 0);
	if (hinted == MAP_FAILED || munmap(hinted, size) != 0)
		return (0);
	return (munmap(page, size) == 0);
}

static void *
tls_thread(void *arg)
{
	(void)arg;
	if (tls_data != 7 || tls_zero != 0)
		return (NULL);
	tls_data = 8;
	tls_zero = 9;
	return (&tls_data);
}

static int
case_tls(void)
{
	pthread_t thread;
	void *result;

	tls_data = 1;
	tls_zero = 2;
	if (pthread_create(&thread, NULL, tls_thread, NULL) != 0 || pthread_join(thread, &result) != 0)
		return (0);
	return (result != NULL && result != (void *)&tls_data && tls_data == 1 && tls_zero == 2);
}

static void *
churn_thread(void *arg)
{
	const uintptr_t round = (uintptr_t)arg;
	volatile unsigned char stack_bytes[256];

	if (pin_to(pthread_self(), (int)(round % (uintptr_t)cpu_count)) != 0)
		return (NULL);
	for (size_t index = 0; index < sizeof(stack_bytes); index++)
		stack_bytes[index] = (unsigned char)round;
	for (size_t index = 0; index < sizeof(stack_bytes); index++)
		if (stack_bytes[index] != (unsigned char)round)
			return (NULL);
	return ((void *)(round + 1));
}

static int
case_join_churn(void)
{
	const uint64_t pages = erx_fiasco_vm_free_pages();

	for (uintptr_t round = 0; round < CHURN_ROUNDS; round++) {
		pthread_t thread;
		void *result;

		if (create_retrying(&thread, NULL, churn_thread, (void *)round) != 0 ||
		    pthread_join(thread, &result) != 0 || result != (void *)(round + 1))
			return (0);
	}
	return (pool_returns_to(pages));
}

static pthread_mutex_t detached_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t detached_changed = PTHREAD_COND_INITIALIZER;
static int detached_done;

static void *
detached_thread(void *arg)
{
	if (pin_to(pthread_self(), (int)((uintptr_t)arg % (uintptr_t)cpu_count)) != 0)
		abort();
	pthread_mutex_lock(&detached_lock);
	detached_done++;
	pthread_cond_signal(&detached_changed);
	pthread_mutex_unlock(&detached_lock);
	return (NULL);
}

static int
case_detached_loop(void)
{
	const uint64_t pages = erx_fiasco_vm_free_pages();
	pthread_attr_t attr;

	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	for (uintptr_t round = 0; round < CHURN_ROUNDS; round++) {
		pthread_t thread;

		if (create_retrying(&thread, &attr, detached_thread, (void *)round) != 0)
			return (0);
	}
	pthread_mutex_lock(&detached_lock);
	while (detached_done != CHURN_ROUNDS)
		pthread_cond_wait(&detached_changed, &detached_lock);
	pthread_mutex_unlock(&detached_lock);
	return (pool_returns_to(pages));
}

static pthread_mutex_t broadcast_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t broadcast_go = PTHREAD_COND_INITIALIZER;
static pthread_cond_t broadcast_arrived = PTHREAD_COND_INITIALIZER;
static int broadcast_generation;
static int broadcast_waiting;
static int broadcast_woken;

static void *
broadcast_thread(void *arg)
{
	if (pin_to(pthread_self(), (int)((uintptr_t)arg % (uintptr_t)cpu_count)) != 0)
		return (NULL);
	for (int round = 0; round < BROADCAST_ROUNDS; round++) {
		pthread_mutex_lock(&broadcast_lock);
		broadcast_waiting++;
		pthread_cond_signal(&broadcast_arrived);
		while (broadcast_generation == round)
			pthread_cond_wait(&broadcast_go, &broadcast_lock);
		broadcast_woken++;
		pthread_cond_signal(&broadcast_arrived);
		pthread_mutex_unlock(&broadcast_lock);
	}
	return ((void *)((uintptr_t)arg + 1));
}

static int
case_cond_broadcast(void)
{
	pthread_t threads[BROADCAST_WAITERS];
	int good = 1;

	for (uintptr_t index = 0; index < BROADCAST_WAITERS; index++)
		if (create_retrying(&threads[index], NULL, broadcast_thread, (void *)index) != 0)
			return (0);
	for (int round = 0; round < BROADCAST_ROUNDS; round++) {
		pthread_mutex_lock(&broadcast_lock);
		while (broadcast_waiting != BROADCAST_WAITERS * (round + 1))
			pthread_cond_wait(&broadcast_arrived, &broadcast_lock);
		broadcast_generation = round + 1;
		pthread_cond_broadcast(&broadcast_go);
		while (broadcast_woken != BROADCAST_WAITERS * (round + 1))
			pthread_cond_wait(&broadcast_arrived, &broadcast_lock);
		pthread_mutex_unlock(&broadcast_lock);
	}
	for (uintptr_t index = 0; index < BROADCAST_WAITERS; index++) {
		void *result;

		if (pthread_join(threads[index], &result) != 0 || result != (void *)(index + 1))
			good = 0;
	}
	return (good);
}

/* Timed out, never early, on the clock the condition variable names. */
static int
timed_wait_expires(clockid_t clock)
{
	pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	pthread_condattr_t attr;
	pthread_cond_t cond;
	struct timespec deadline;
	int64_t started;
	int status;

	pthread_condattr_init(&attr);
	pthread_condattr_setclock(&attr, clock);
	pthread_cond_init(&cond, &attr);
	started = now_ns(clock);
	deadline.tv_sec = (time_t)((started + TIMED_WAIT_NS) / NS_PER_SEC);
	deadline.tv_nsec = (long)((started + TIMED_WAIT_NS) % NS_PER_SEC);
	pthread_mutex_lock(&lock);
	status = pthread_cond_timedwait(&cond, &lock, &deadline);
	pthread_mutex_unlock(&lock);
	return (status == ETIMEDOUT && now_ns(clock) - started >= TIMED_WAIT_NS);
}

static pthread_mutex_t signal_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t signal_cond = PTHREAD_COND_INITIALIZER;
static int signal_ready;

static void *
signal_thread(void *arg)
{
	if (pin_to(pthread_self(), cpu_count - 1) != 0)
		return (NULL);
	pthread_mutex_lock(&signal_lock);
	signal_ready = 1;
	pthread_cond_signal(&signal_cond);
	pthread_mutex_unlock(&signal_lock);
	return (arg);
}

static int
case_timed_waits(void)
{
	pthread_t thread;
	struct timespec deadline;
	int status = 0;

	if (!timed_wait_expires(CLOCK_REALTIME) || !timed_wait_expires(CLOCK_MONOTONIC))
		return (0);
	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += SETTLE_SECONDS;
	pthread_mutex_lock(&signal_lock);
	if (pthread_create(&thread, NULL, signal_thread, NULL) != 0)
		return (0);
	while (!signal_ready && status == 0)
		status = pthread_cond_timedwait(&signal_cond, &signal_lock, &deadline);
	pthread_mutex_unlock(&signal_lock);
	return (pthread_join(thread, NULL) == 0 && status == 0);
}

static int
case_nanosleep_not_early(void)
{
	const struct timespec wait = { 0, TIMED_WAIT_NS };
	const int64_t started = now_ns(CLOCK_MONOTONIC);

	return (nanosleep(&wait, NULL) == 0 && now_ns(CLOCK_MONOTONIC) - started >= TIMED_WAIT_NS);
}

static pthread_mutex_t counter_lock = PTHREAD_MUTEX_INITIALIZER;
static long counter;

static void *
counter_thread(void *arg)
{
	if (pin_to(pthread_self(), (int)((uintptr_t)arg % (uintptr_t)cpu_count)) != 0)
		return (NULL);
	for (int round = 0; round < MUTEX_ROUNDS; round++) {
		pthread_mutex_lock(&counter_lock);
		counter++;
		pthread_mutex_unlock(&counter_lock);
	}
	return ((void *)((uintptr_t)arg + 1));
}

static int
run_workers(void *(*entry)(void *))
{
	pthread_t threads[WORKERS];
	int good = 1;

	for (uintptr_t index = 0; index < WORKERS; index++)
		if (pthread_create(&threads[index], NULL, entry, (void *)index) != 0)
			return (0);
	for (uintptr_t index = 0; index < WORKERS; index++) {
		void *result;

		if (pthread_join(threads[index], &result) != 0 || result != (void *)(index + 1))
			good = 0;
	}
	return (good);
}

static int
case_mutex_contended(void)
{
	return (run_workers(counter_thread) && counter == (long)WORKERS * MUTEX_ROUNDS);
}

/* Blocks a thread hands on: another thread checks and frees what this one filled. */
static pthread_mutex_t handoff_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned char *handoff[MALLOC_SLOTS];
static size_t handoff_size[MALLOC_SLOTS];

static size_t
size_of_round(unsigned *state)
{
	*state = *state * 1103515245u + 12345u;
	/* Mostly slabs; every 64th block is big enough for its own mmap. */
	return ((*state >> 16) % 64 == 0 ? 1024 * 1024 + (*state >> 20) : 1 + (*state >> 16) % 4096);
}

static int
block_is(const unsigned char *block, size_t size)
{
	const unsigned char fill = (unsigned char)(size * 31);

	for (size_t index = 0; index < size; index++)
		if (block[index] != fill)
			return (0);
	return (1);
}

static void *
malloc_thread(void *arg)
{
	unsigned state = (unsigned)(uintptr_t)arg + 1;

	if (pin_to(pthread_self(), (int)((uintptr_t)arg % (uintptr_t)cpu_count)) != 0)
		return (NULL);
	for (int round = 0; round < MALLOC_ROUNDS; round++) {
		size_t size = size_of_round(&state);
		const size_t slot = (state >> 8) % MALLOC_SLOTS;
		unsigned char *block = malloc(size);
		unsigned char *taken;
		size_t taken_size;

		if (block == NULL)
			return (NULL);
		memset(block, (int)(unsigned char)(size * 31), size);
		pthread_mutex_lock(&handoff_lock);
		taken = handoff[slot];
		taken_size = handoff_size[slot];
		handoff[slot] = block;
		handoff_size[slot] = size;
		pthread_mutex_unlock(&handoff_lock);
		if (taken != NULL) {
			if (!block_is(taken, taken_size))
				return (NULL);
			free(taken);
		}
	}
	return ((void *)((uintptr_t)arg + 1));
}

static int
case_malloc_threads(void)
{
	int good = run_workers(malloc_thread);

	for (size_t slot = 0; slot < MALLOC_SLOTS; slot++) {
		if (handoff[slot] != NULL && !block_is(handoff[slot], handoff_size[slot]))
			good = 0;
		free(handoff[slot]);
	}
	return (good);
}

static int
case_realloc_grows(void)
{
	size_t size = 16;
	size_t last = 0;
	unsigned char *block = malloc(size);

	if (block == NULL)
		return (0);
	block[0] = 0x5a;
	block[size - 1] = 0xa5;
	last = size - 1;
	while (size < 8 * 1024 * 1024) {
		size *= 4;
		block = realloc(block, size);
		if (block == NULL || block[0] != 0x5a || block[last] != 0xa5)
			return (0);
		block[size - 1] = 0xa5;
		last = size - 1;
	}
	free(block);
	return (1);
}

/* mov w0, #42; ret */
static const uint32_t code_bytes[] = { 0x52800540u, 0xd65f03c0u };
static int (*code_entry)(void);
static int code_stop;

static void *
code_thread(void *arg)
{
	if (pin_to(pthread_self(), cpu_count - 1) != 0)
		return (NULL);
	while (!__atomic_load_n(&code_stop, __ATOMIC_ACQUIRE))
		if (code_entry() != 42)
			return (NULL);
	return (arg);
}

/* Asking for the protection a page already has does not disturb a thread running on it. */
static int
case_mprotect_same_runs(void)
{
	const size_t page = (size_t)sysconf(_SC_PAGESIZE);
	unsigned char *code = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	pthread_t thread;
	void *result;
	int good = 1;

	if (code == MAP_FAILED)
		return (0);
	memcpy(code, code_bytes, sizeof(code_bytes));
	__builtin___clear_cache((char *)code, (char *)code + sizeof(code_bytes));
	if (mprotect(code, page, PROT_READ | PROT_EXEC) != 0)
		return (0);
	code_entry = (int (*)(void))(uintptr_t)code;
	if (pthread_create(&thread, NULL, code_thread, code) != 0)
		return (0);
	for (int round = 0; round < MPROTECT_ROUNDS; round++)
		if (mprotect(code, page, PROT_READ | PROT_EXEC) != 0)
			good = 0;
	__atomic_store_n(&code_stop, 1, __ATOMIC_RELEASE);
	if (pthread_join(thread, &result) != 0 || result != code)
		good = 0;
	return (good && munmap(code, page) == 0);
}

/* A range over a hole is refused whole, and the pages either side keep what they held. */
static int
case_mprotect_hole(void)
{
	const size_t page = (size_t)sysconf(_SC_PAGESIZE);
	unsigned char *base = mmap(NULL, 3 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (base == MAP_FAILED)
		return (0);
	base[0] = 3;
	base[2 * page] = 4;
	if (munmap(base + page, page) != 0 || mprotect(base, 3 * page, PROT_READ) != -1 || errno != ENOMEM)
		return (0);
	base[0]++;
	base[2 * page]++;
	if (base[0] != 4 || base[2 * page] != 5)
		return (0);
	return (mprotect(base, 0, PROT_READ) == 0 && munmap(base, page) == 0 && munmap(base + 2 * page, page) == 0);
}

static void *
cancel_thread(void *arg)
{
	(void)arg;
	if (pin_to(pthread_self(), cpu_count - 1) != 0)
		return (NULL);
	for (;;)
		pthread_testcancel();
}

/* No signal interrupts a thread: the request lands at its next cancellation point. */
static int
case_cancel(void)
{
	pthread_t thread;
	void *result;

	if (pthread_create(&thread, NULL, cancel_thread, NULL) != 0 || pthread_cancel(thread) != 0)
		return (0);
	return (pthread_join(thread, &result) == 0 && result == PTHREAD_CANCELED);
}

/* The anonymous memory calls, and what stays refused. */
static int
case_mmap_mprotect(void)
{
	const size_t page = (size_t)sysconf(_SC_PAGESIZE);
	unsigned char *zeroed = mmap(NULL, 4 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	unsigned char *reserved = mmap(NULL, 4 * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (zeroed == MAP_FAILED || reserved == MAP_FAILED)
		return (0);
	for (size_t index = 0; index < 4 * page; index++)
		if (zeroed[index] != 0)
			return (0);
	if (mprotect(reserved + page, 2 * page, PROT_READ | PROT_WRITE) != 0)
		return (0);
	reserved[page] = 1;
	reserved[3 * page - 1] = 2;
	if (mprotect(reserved + page, page, PROT_READ) != 0 || reserved[page] != 1)
		return (0);
	if (munmap(zeroed + page, page) != 0 || munmap(zeroed, 4 * page) != 0 || munmap(reserved, 4 * page) != 0)
		return (0);
	return (mmap(NULL, page, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED &&
	    errno == EACCES && mmap(NULL, page, PROT_READ, MAP_PRIVATE, 3, 0) == MAP_FAILED && errno == ENOSYS);
}

static int
case_refusals(void)
{
	errno = 0;
	if (getpid() != 1 || getuid() != 0 || fork() != -1 || errno != ENOSYS)
		return (0);
	errno = 0;
	if (fopen("/none", "r") != NULL || errno != ENOSYS)
		return (0);
	return (pthread_kill(pthread_self(), 1) == ENOSYS);
}

static void
report(const char *name, int good)
{
	printf("erx: musl: %s %s\n", name, good ? "ok" : "failed");
}

static int constructed;

__attribute__((constructor)) static void
constructor_ran(void)
{
	constructed = 1;
}

/* exit() runs its handlers, then the destructors, then flushes stdio. */
__attribute__((destructor)) static void
destructor_ran(void)
{
	printf("erx: musl: done\n");
}

static void
at_exit_ran(void)
{
	printf("erx: musl: atexit ran\n");
}

int
main(int argc, char **argv)
{
	(void)argv;
	printf("erx: musl: main runs, %d argument\n", argc);
	cpu_count = count_cpus();
	printf("erx: musl: cpus %d\n", cpu_count);
	if (cpu_count == 0)
		abort();
	atexit(at_exit_ran);
	report("constructor", constructed);
	report("printf_float", case_printf_float());
	report("mmap_flags", case_mmap_flags());
	report("tls", case_tls());
	report("join_churn", case_join_churn());
	report("detached_loop", case_detached_loop());
	report("cond_broadcast", case_cond_broadcast());
	report("timed_waits", case_timed_waits());
	report("nanosleep_not_early", case_nanosleep_not_early());
	report("mutex_contended", case_mutex_contended());
	report("malloc_threads", case_malloc_threads());
	report("realloc_grows", case_realloc_grows());
	report("mmap_mprotect", case_mmap_mprotect());
	report("mprotect_same_runs", case_mprotect_same_runs());
	report("mprotect_hole", case_mprotect_hole());
	report("cancel", case_cancel());
	report("refusals", case_refusals());
	return (0);
}
