/*
 * Modified by erXos
 *
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 1996-2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * %CopyrightEnd%
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#ifdef ISC32
#define _POSIX_SOURCE
#define _XOPEN_SOURCE
#endif

#include <sys/times.h>		/* ! */
#include <time.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <ctype.h>
#include <limits.h>
#include <sys/select.h>

#include "liberx/backend/api.h"

#ifdef ISC32
#include <sys/bsdtypes.h>
#endif

#ifdef HAVE_FCNTL_H
#include <fcntl.h>
#endif
#ifdef HAVE_SYS_IOCTL_H
#include <sys/ioctl.h>
#endif

#ifdef ADDRESS_SANITIZER
#  include <sanitizer/asan_interface.h>
#endif

#define ERTS_WANT_BREAK_HANDLING
#define WANT_NONBLOCKING    /* must define this to pull in defs from sys.h */
#include "sys.h"
#include "erl_thr_progress.h"


#include "erl_threads.h"

#include "erl_mseg.h"

#define MAX_VSIZE 16		/* Max number of entries allowed in an I/O
				 * vector sock_sendv().
				 */
/*
 * Don't need global.h, but bif_table.h (included by bif.h),
 * won't compile otherwise
 */
#include "global.h"
#include "bif.h"

#include "erl_cpu_topology.h"
#include "erl_osenv.h"
#include "erx_stdio.h"
#include "erl_dyn_lock_check.h"
extern int  driver_interrupt(int, int);
extern void do_break(void);

extern void erl_sys_args(int*, char**);

/* The following two defs should probably be moved somewhere else */

extern void erts_sys_init_float(void);

#ifdef DEBUG
static int debug_log = 0;
#endif

static erts_atomic32_t have_prepared_crash_dump;
#define ERTS_PREPARED_CRASH_DUMP \
  ((int) erts_atomic32_xchg_nob(&have_prepared_crash_dump, 1))

erts_atomic_t sys_misc_mem_sz;

static int max_files = -1;

/* 
 * a few variables used by the break handler 
 */
erts_atomic32_t erts_break_requested;
#define ERTS_SET_BREAK_REQUESTED \
  erts_atomic32_set_nob(&erts_break_requested, (erts_aint32_t) 1)
#define ERTS_UNSET_BREAK_REQUESTED \
  erts_atomic32_set_nob(&erts_break_requested, (erts_aint32_t) 0)


/* set early so the break handler has access to initial mode */
static void (*tty_reset)(void);
/* assume yes initially, ttsl_init will clear it */
int using_oldshell = 1;

UWord sys_page_size;
UWord sys_large_page_size;

static UWord
get_page_size(void)
{
    return (UWord) getpagesize();
}

static UWord
get_large_page_size(void)
{
#ifdef HAVE_LINUX_THP
    FILE *fp;
    UWord result;
    int matched;

    fp = fopen("/sys/kernel/mm/transparent_hugepage/hpage_pmd_size", "r");
    if (fp == NULL)
        return 0;
    matched = fscanf(fp, "%lu", &result);
    fclose(fp);
    return matched == 1 ? result : 0;
#else
    return 0;
#endif
}

Uint
erts_sys_misc_mem_sz(void)
{
    return erts_atomic_read_mb(&sys_misc_mem_sz);
}

/*
 * reset the terminal to the original settings on exit
 */
void sys_tty_reset(int exit_code)
{
  if (tty_reset != NULL)
    tty_reset();
}

void erx_sys_set_tty_reset(void (*restore)(void))
{
  tty_reset = restore;
}

#ifdef __tile__
/* Direct malloc to spread memory around the caches of multiple tiles. */
#include <malloc.h>
#if defined(MALLOC_USE_HASH)
MALLOC_USE_HASH(1);
#endif
#endif


#ifdef ERTS_THR_HAVE_SIG_FUNCS

/*
 * Child thread inherits parents signal mask at creation. In order to
 * guarantee that the main thread will receive all SIGINT, and
 * SIGUSR1 signals sent to the process, we block these signals in the
 * parent thread when creating a new thread.
 */

static sigset_t thr_create_sigmask;

#endif /* #ifdef ERTS_THR_HAVE_SIG_FUNCS */

typedef struct {
#ifdef ERTS_THR_HAVE_SIG_FUNCS
    sigset_t saved_sigmask;
#endif
    int sched_bind_data;
} erts_thr_create_data_t;

/*
 * thr_create_prepare() is called in parent thread before thread creation.
 * Returned value is passed as argument to thr_create_cleanup().
 */
static void *
thr_create_prepare(void)
{
    erts_thr_create_data_t *tcdp;

    tcdp = erts_alloc(ERTS_ALC_T_TMP, sizeof(erts_thr_create_data_t));

#ifdef ERTS_THR_HAVE_SIG_FUNCS
    erts_thr_sigmask(SIG_BLOCK, &thr_create_sigmask, &tcdp->saved_sigmask);
#endif
    tcdp->sched_bind_data = erts_sched_bind_atthrcreate_prepare();

    return (void *) tcdp;
}


/* thr_create_cleanup() is called in parent thread after thread creation. */
static void
thr_create_cleanup(void *vtcdp)
{
    erts_thr_create_data_t *tcdp = (erts_thr_create_data_t *) vtcdp;

    erts_sched_bind_atthrcreate_parent(tcdp->sched_bind_data);

#ifdef ERTS_THR_HAVE_SIG_FUNCS
    /* Restore signalmask... */
    erts_thr_sigmask(SIG_SETMASK, &tcdp->saved_sigmask, NULL);
#endif

    erts_free(ERTS_ALC_T_TMP, tcdp);
}

#ifdef HAVE_LINUX_THP
static int
is_linux_thp_enabled(void)
{
    FILE *fp;
    char always[9], madvise[10], never[8];
    int matched;

    fp = fopen("/sys/kernel/mm/transparent_hugepage/enabled", "r");
    if (fp == NULL)
        return 0;
    matched = fscanf(fp, "%8s %9s %7s", always, madvise, never);
    fclose(fp);
    if (matched != 3 || strcmp("[never]", never) == 0)
        return 0;
    return strcmp("[always]", always) != 0 || strcmp("[madvise]", madvise) != 0;
}

#define ALIGN_DOWN(x, a) ((void*)(((UWord)(x)) & ~((a) - 1)))

static void
enable_linux_thp_for_text(void)
{
    FILE *fp;
    char *from, *to;
    extern char etext;  /* see end(3) for details */

    /*
     * If sysfs(5) is not accessible we will not be able to determine the THP
     * page size.  While we could madvise(2) the whole .text segment and just
     * hope for the best, other things will likely go wrong so we simply fail
     * fast instead.
     */
    if (sys_large_page_size == 0)
        return;

    /*
     * Our use of madvise(... MADV_HUGEPAGE) only makes sense when the THP
     * behavior is set to the default of [madvise].  Check that we are in this
     * mode and exit if we are not.
     */
    if (is_linux_thp_enabled() == 0)
        return;

    fp = fopen("/proc/self/maps", "r");
    if (fp == NULL)
        return;

    /*
     * Iterate through the current process mappings to find the text segment.
     * When they are found, madvise their memory region to use huge pages.
     */
    while (fscanf(fp, "%p-%p %*[^\n]\n", &from, &to) == 2) {
        if (to < &etext)
            continue;
        if (from > &etext)
            break;
        if ((UWord)from % sys_large_page_size != 0)
            break;
        to = ALIGN_DOWN(to, sys_large_page_size);
        if (to - from < sys_large_page_size)
            break;
        madvise(from, to - from, MADV_HUGEPAGE);
    }
    fclose(fp);
}
#endif

static void
thr_create_prepare_child(void *vtcdp)
{
    erts_thr_create_data_t *tcdp = (erts_thr_create_data_t *) vtcdp;

#ifdef ERTS_ENABLE_LOCK_COUNT
    erts_lcnt_thread_setup();
#endif

    erts_sched_bind_atthrcreate_child(tcdp->sched_bind_data);
}

void
erts_sys_pre_init(void)
{
    erts_thr_init_data_t eid = ERTS_THR_INIT_DATA_DEF_INITER;

    erts_printf_add_cr_to_stdout = 1;
    erts_printf_add_cr_to_stderr = 1;

    eid.thread_create_child_func = thr_create_prepare_child;
    /* Before creation in parent */
    eid.thread_create_prepare_func = thr_create_prepare;
    /* After creation in parent */
    eid.thread_create_parent_func = thr_create_cleanup;

    sys_page_size = get_page_size();
    sys_large_page_size = get_large_page_size();

#ifdef HAVE_LINUX_THP
    enable_linux_thp_for_text();
#endif

#ifdef ERTS_ENABLE_LOCK_COUNT
    erts_lcnt_pre_thr_init();
#endif

    erts_thr_init(&eid);

#ifdef ERTS_ENABLE_LOCK_COUNT
    erts_lcnt_post_thr_init();
#endif

#ifdef ERTS_ENABLE_LOCK_CHECK
    erts_lc_init();
#endif
#ifdef ERTS_DYN_LOCK_CHECK
    erts_dlc_init();
#endif

    erts_init_sys_time_sup();


    erts_atomic32_init_nob(&erts_break_requested, 0);
    erts_atomic32_init_nob(&have_prepared_crash_dump, 0);


    erts_atomic_init_nob(&sys_misc_mem_sz, 0);
}

void erts_sys_scheduler_init(void) {
}

void
erl_sys_init(void)
{

#ifdef USE_SETLINEBUF
    setlinebuf(stdout);
#else
    setvbuf(stdout, (char *)NULL, _IOLBF, BUFSIZ);
#endif

    erts_sys_init_float();
}

/*
 * Nothing tells whether an area is readable without a pipe for write to fail on, so a
 * crash dump leaves out the stacks it cannot prove readable.
 */
int
erts_sys_is_area_readable(char *start, char *stop) {
    (void) start;
    (void) stop;
    return 0;
}

static ERTS_INLINE int
prepare_crash_dump(int secs)
{
#define NUFBUF (3)
    DeclareTmpHeapNoproc(heap,NUFBUF);
    Port *heart_port;
    Eterm *hp = heap;
    Eterm list = NIL;
    int has_heart = 0;

    (void) secs;
    UseTmpHeapNoproc(NUFBUF);

    if (ERTS_PREPARED_CRASH_DUMP)
	return 0; /* We have already been called */

    heart_port = erts_get_heart_port();

    /* close all viable sockets via emergency close callbacks.
     * Specifically we want to close epmd sockets.
     */

    erts_emergency_close_ports();

    if (heart_port) {
	has_heart = 1;
	list = CONS(hp, make_small(8), list); hp += 2;
	/* send to heart port, CMD = 8, i.e. prepare crash dump =o */
	erts_port_output(NULL, ERTS_PORT_SIG_FLG_FORCE_IMM_CALL, heart_port,
			 heart_port->common.id, list, NULL);
    }

    UnUseTmpHeapNoproc(NUFBUF);
#undef NUFBUF
    return has_heart;
}

int erts_sys_prepare_crash_dump(int secs)
{
    return prepare_crash_dump(secs);
}

/* No signal reaches a program of erXos, so os:set_signal/2 is badarg. */
int erts_set_signal(Eterm signal, Eterm type) {
    (void) signal;
    (void) type;
    return 0;
}

/* A raw terminal delivers Ctrl+C as a byte, to erx_console, and nothing else sends a break. */
void erts_set_ignore_break(void) {
}

void erts_replace_intr(void) {
}

void init_break_handler(void)
{
}

int sys_max_files(void)
{
   return max_files;
}

/************************** OS info *******************************/

/* Used by erlang:info/1. */
/* (This code was formerly in drv.XXX/XXX_os_drv.c) */

char os_type[] = "unix";

/*
 * erXos's name and release, never the host's: abi/erx_abi.txt's uname_sysname
 * and uname_release, which uname(1) and uname(3) report too. As stock ERTS
 * derives both from uname(2), the flavor is the name in lower case and the
 * version the release's numbers.
 */
void os_flavor(char* namebuf, unsigned size) {
    static const char name[] = ERX_UNAME_SYSNAME_STRING;
    unsigned i;

    if (size == 0)
        return;
    for (i = 0; i + 1 < size && name[i] != '\0'; i++)
        namebuf[i] = (char)tolower((unsigned char)name[i]);
    namebuf[i] = '\0';
}

/*
 * The number at *cursor, 0 where none is, and INT_MAX where it would not fit;
 * *cursor then moves past all its digits and one '.' after them.
 */
static int release_number(const char **cursor) {
    int value = 0;

    for (; isdigit((unsigned char)**cursor); (*cursor)++)
        value = value > (INT_MAX - 9) / 10 ? INT_MAX : value * 10 + (**cursor - '0');
    if (**cursor == '.')
        (*cursor)++;
    return value;
}

void os_version(int *pMajor, int *pMinor, int *pBuild) {
    const char *release = ERX_UNAME_RELEASE_STRING;

    *pMajor = release_number(&release);
    *pMinor = release_number(&release);
    *pBuild = release_number(&release);
}

void erts_do_break_handling(void)
{

    /*
     * Most functions that do_break() calls are intentionally not thread safe;
     * therefore, make sure that all threads but this one are blocked before
     * proceeding!
     */
    erts_thr_progress_block();

    /* call the break handling function, reset the flag */
    do_break();

    ERTS_UNSET_BREAK_REQUESTED;

    fflush(stdout);

    erts_thr_progress_unblock();
}


/* Fills in the systems representation of the Beam process identifier.
** The Pid is put in STRING representation in the supplied buffer,
** no interpretatione of this should be done by the rest of the
** emulator. The buffer should be at least 21 bytes long.
*/
void sys_get_pid(char *buffer, size_t buffer_size){
    pid_t p = getpid();
    /* Assume the pid is scalar and can rest in an unsigned long... */
    erts_snprintf(buffer, buffer_size, "%lu",(unsigned long) p);
}

int sys_get_hostname(char *buf, size_t size)
{
/* erXos has no host name to read; this one seeds the local node id, with the time and the pid. */
    if (size < sizeof("nohost"))
        return -1;
    strcpy(buf, "nohost");
    return 0;
}

void sys_init_io(void) { }
void erts_sys_alloc_init(void) { }

extern const char pre_loaded_code[];
extern Preload pre_loaded[];

void *erts_sys_alloc(ErtsAlcType_t t, void *x, Uint sz)
{
    void *res = malloc((size_t) sz);
#if HAVE_ERTS_MSEG
    if (!res) {
	erts_mseg_clear_cache();
	return malloc((size_t) sz);
    }
#endif
    return res;
}

void *erts_sys_realloc(ErtsAlcType_t t, void *x, void *p, Uint sz)
{
    void *res = realloc(p, (size_t) sz);
#if HAVE_ERTS_MSEG
    if (!res) {
	erts_mseg_clear_cache();
	return realloc(p, (size_t) sz);
    }
#endif
    return res;
}

void erts_sys_free(ErtsAlcType_t t, void *x, void *p)
{
    free(p);
}

/* Return a pointer to a vector of names of preloaded modules */

Preload*
sys_preloaded(void)
{
    return pre_loaded;
}

/* Return a pointer to preloaded code for module "module" */
unsigned char*
sys_preload_begin(Preload* p)
{
    return p->code;
}

/* Clean up if allocated */
void sys_preload_end(Preload* p)
{
    /* Nothing */
}

/* Read a key from console, used by break.c
   Here we assume that all schedulers are stopped so that erl_poll
   does not interfere with the select below.
*/
int sys_get_key(int fd) {
    int c, ret;
    unsigned char rbuf[64] = {0};
    fd_set fds;

    fflush(stdout);		/* Flush query ??? */

    FD_ZERO(&fds);
    FD_SET(fd,&fds);

    ret = select(fd+1, &fds, NULL, NULL, NULL);

    if (ret == 1) {
        do {
            c = read(fd,rbuf,64);
        } while (c < 0 && errno == EAGAIN);
        if (c <= 0)
            return c;
    }
    return rbuf[0];
}


extern int erts_initialized;
void
erl_assert_error(const char* expr, const char* func, const char* file, int line)
{
    fflush(stdout);
    fprintf(stderr, "%s:%d:%s() Assertion failed: %s\n",
            file, line, func, expr);
    fflush(stderr);
    /* A domain ends as a crash with this slogan; the system domain aborts. */
    erx_crash_area_fail("%s:%d:%s() Assertion failed: %s\n", file, line, func, expr);
    abort();
}

#ifdef DEBUG

void
erl_debug(char* fmt, ...)
{
    char sbuf[1024];		/* Temporary buffer. */
    va_list va;

    if (debug_log) {
	va_start(va, fmt);
	vsprintf(sbuf, fmt, va);
	va_end(va);
	fprintf(stderr, "%s", sbuf);
    }
}

#endif /* DEBUG */

/* ERTS is done with the thread that started it: a wait nothing ends, on a word only it knows. */
void
erts_sys_main_thread(void)
{
    uint32_t word = 0;

#ifdef ERTS_ENABLE_LOCK_CHECK
    erts_lc_set_thread_name("main");
#endif
    while (1)
        (void) erx_umtx_wait((uint64_t) (uintptr_t) &word, 0, ERX_WAIT_FOREVER);
}

void
erl_sys_late_init(void)
{
}

void
erl_sys_args(int* argc, char** argv)
{
    ASSERT(argc && argv);

    erts_sys_env_init();
}
