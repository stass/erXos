/*
 * Modified by erXos
 *
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 * 
 * Copyright Ericsson AB 1997-2025. All Rights Reserved.
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
 * Modified by erXos: ERTS's clocks are liberx's, and the zone is UTC.
 *
 * %CopyrightEnd%
 *
 * This file handles differences between different Unix systems.
 * This should be the only place with conditional compilation
 * depending on the type of OS.
 */

#ifndef _ERL_UNIX_SYS_H
#define _ERL_UNIX_SYS_H

#include <stdio.h>
#include <math.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <memory.h>

#if defined(__sun__) && defined(__SVR4) && !defined(__EXTENSIONS__)
#   define __EXTENSIONS__
#   include <sys/types.h>
#   undef __EXTENSIONS__
#else
#   include <sys/types.h>
#endif
#include <sys/stat.h>
#include <sys/param.h>
#include <fcntl.h>
#include "erl_errno.h"
#include <signal.h>
#include <setjmp.h>

#ifdef HAVE_SYS_SOCKETIO_H
#   include <sys/socketio.h>
#endif
#ifdef HAVE_SYS_SOCKIO_H
#   include <sys/sockio.h>
#endif

#ifdef HAVE_NET_ERRNO_H
#include <net/errno.h>
#endif

#ifdef HAVE_DIRENT_H
#  include <dirent.h>
#endif

#ifdef HAVE_UNISTD_H
#   include <unistd.h>
#endif

#include <time.h>
#if HAVE_SYS_TIME_H
#   include <sys/time.h>
#endif

#include <sys/times.h>

#ifdef HAVE_SYS_RESOURCE_H
#  include <sys/resource.h>
#endif

#ifdef HAVE_IEEEFP_H
#include <ieeefp.h>
#endif

#include <pwd.h>

#ifndef HZ
#define HZ 60
#endif

#ifdef NETDB_H_NEEDS_IN_H
#include <netinet/in.h>
#endif
#include <netdb.h>

#ifdef HAVE_MACH_ABSOLUTE_TIME
#include <mach/mach_time.h>
#endif

#ifndef RETSIGTYPE
#define RETSIGTYPE void
#endif

/*
 * Make sure that MAXPATHLEN is defined.
 */
#ifndef MAXPATHLEN
#   ifdef PATH_MAX
#       define MAXPATHLEN PATH_MAX
#   else
#       define MAXPATHLEN 2048
#   endif
#endif

/*
 * Min number of async threads
 */
#define  ERTS_MIN_NO_OF_ASYNC_THREADS 0

/* File descriptors are numbers anc consecutively allocated on Unix */
#define  ERTS_SYS_CONTINOUS_FD_NUMBERS


void erts_sys_env_init(void);

/*
** For the erl_timer_sup module.
*/
typedef time_t erts_time_t;

typedef struct timeval SysTimeval;

void sys_gettimeofday(SysTimeval *tv);

/* The zone is UTC, which has no daylight saving: an entry's environment names no other. */
#define sys_daylight 0

#if SIZEOF_LONG == 8
typedef long ErtsMonotonicTime;
typedef long ErtsSysHrTime;
#elif SIZEOF_LONG_LONG == 8
typedef long long ErtsMonotonicTime;
typedef long long ErtsSysHrTime;
#else
#error No signed 64-bit type found...
#endif

typedef ErtsMonotonicTime ErtsSystemTime;
typedef ErtsSysHrTime ErtsSysPerfCounter;

#define ERTS_MONOTONIC_TIME_MIN ((ErtsMonotonicTime) (1ULL << 63))
#define ERTS_MONOTONIC_TIME_MAX (~ERTS_MONOTONIC_TIME_MIN)

/*
 * OS monotonic time and OS system time, both in nanoseconds: erx_clock_ns and
 * erx_time_wall_ns, in sys_time.c.
 */
#undef ERTS_HAVE_OS_MONOTONIC_TIME_SUPPORT
#undef ERTS_COMPILE_TIME_MONOTONIC_TIME_UNIT
#define ERTS_HAVE_OS_MONOTONIC_TIME_SUPPORT 1
#define ERTS_COMPILE_TIME_MONOTONIC_TIME_UNIT (1000*1000*1000)

ErtsSystemTime erts_os_system_time(void);
ErtsMonotonicTime erts_os_monotonic_time(void);
void erts_os_times(ErtsMonotonicTime *, ErtsSystemTime *);

/*
 * erts_sys_hrtime() is the highest resolution
 * time function found. Time unit is nano-seconds.
 */
ErtsSysHrTime erts_sys_hrtime(void);
#define ERTS_HRTIME_UNIT (1000*1000*1000)

struct erts_sys_time_read_only_data__ {
    ErtsSysPerfCounter (*perf_counter)(void);
    ErtsSysPerfCounter perf_counter_unit;
};

typedef struct {
    union {
	struct erts_sys_time_read_only_data__ o;
	char align__[(((sizeof(struct erts_sys_time_read_only_data__) - 1)
		       / ASSUMED_CACHE_LINE_SIZE) + 1)
		     * ASSUMED_CACHE_LINE_SIZE];
    } r;
} ErtsSysTimeData__;

extern ErtsSysTimeData__ erts_sys_time_data__;

/* A group's CPU usage in milliseconds; 0 where it is unsupported. */
int erts_sys_cpu_time_ms(ErtsMonotonicTime *user, ErtsMonotonicTime *sys);

/* The boot information page's environment: NUL-ended KEY=VALUE words. */
void erx_runtime_env(const char **words, size_t *length);

/*
 * Functions for getting the performance counter
 */

ERTS_GLB_INLINE ErtsSysPerfCounter erts_sys_perf_counter(void);
#define erts_sys_perf_counter_unit() erts_sys_time_data__.r.o.perf_counter_unit

#if ERTS_GLB_INLINE_INCL_FUNC_DEF

ERTS_GLB_FORCE_INLINE ErtsSysPerfCounter
erts_sys_perf_counter(void)
{
    return (*erts_sys_time_data__.r.o.perf_counter)();
}

#endif /* ERTS_GLB_INLINE_INCL_FUNC_DEF */

/*
 * Functions for measuring CPU time
 *
 * Note that gethrvtime is time per process and clock_gettime is per thread.
 */

#if (defined(HAVE_GETHRVTIME) || defined(HAVE_CLOCK_GETTIME_CPU_TIME))
typedef long long SysCpuTime;
typedef struct timespec SysTimespec;

#if defined(HAVE_GETHRVTIME)
#define sys_gethrvtime() gethrvtime()
#define sys_get_cputime(t,tp) (t) = sys_gethrvtime(), \
        (tp).tv_sec = (time_t)((t)/1000000000LL),     \
        (tp).tv_nsec = (long)((t)%1000000000LL)
int sys_start_hrvtime(void);
int sys_stop_hrvtime(void);

#elif defined(HAVE_CLOCK_GETTIME_CPU_TIME)
#define sys_clock_gettime(cid,tp) clock_gettime((cid),&(tp))
#define sys_get_cputime(t,tp) sys_clock_gettime(CLOCK_THREAD_CPUTIME_ID,(tp))

#endif
#endif

/* No use in having other resolutions than 1 Ms. */
#define SYS_CLOCK_RESOLUTION 1

ERTS_GLB_INLINE struct tm *sys_localtime_r(time_t *the_clock, struct tm *buff);

#if ERTS_GLB_INLINE_INCL_FUNC_DEF

ERTS_GLB_INLINE struct tm *sys_localtime_r(time_t *the_clock, struct tm *buff) {
#ifdef HAVE_LOCALTIME_R
    tzset(); /* POSIX.1-2004 does not require tzset to be called within
                localtime_r, so if summer/winter-time has passed localtime_r
                will return the time when Erlang was started. So we need to
                call tzset() before all localtime_r calls.

                localtime already calls tzset for each call, so the performance
                penalty should be acceptable.... */
    return localtime_r(the_clock, buff);
#else
    return localtime(the_clock);
#endif
}

#endif /* ERTS_GLB_INLINE_INCL_FUNC_DEF */


/*
 * Handling of floating point exceptions.
 */

#ifdef USE_ISINF_ISNAN		/* simulate finite() */
#  define isfinite(f) (!isinf(f) && !isnan(f))
#  define HAVE_ISFINITE
#elif (defined(__GNUC__) && !defined(__llvm__)) && defined(HAVE_FINITE)
/* We use finite in gcc as it emits assembler instead of
   the function call that isfinite emits. The assembler is
   significantly faster. */
#  ifdef isfinite
#     undef isfinite
#  endif
#  define isfinite finite
#  ifndef HAVE_ISFINITE
#    define HAVE_ISFINITE
#  endif
#elif defined(isfinite) && !defined(HAVE_ISFINITE)
#  define HAVE_ISFINITE
#elif !defined(HAVE_ISFINITE) && defined(HAVE_FINITE)
#  define isfinite finite
#  define HAVE_ISFINITE
#endif

#define erts_isfinite isfinite

#  define __ERTS_FP_CHECK_INIT(fpexnp) do {} while (0)
#  define __ERTS_FP_ERROR(fpexnp, f, Action) if (!isfinite(f)) { Action; } else {}
#  define __ERTS_FP_ERROR_THOROUGH(fpexnp, f, Action) __ERTS_FP_ERROR(fpexnp, f, Action)
#  define __ERTS_SAVE_FP_EXCEPTION(fpexnp)
#  define __ERTS_RESTORE_FP_EXCEPTION(fpexnp)

#define erts_sys_block_fpe() 0
#define erts_sys_unblock_fpe(x) do{}while(0)

#define ERTS_FP_CHECK_INIT(p)		__ERTS_FP_CHECK_INIT(&(p)->fp_exception)
#define ERTS_FP_ERROR(p, f, A)		__ERTS_FP_ERROR(&(p)->fp_exception, f, A)
#define ERTS_FP_ERROR_THOROUGH(p, f, A)	__ERTS_FP_ERROR_THOROUGH(&(p)->fp_exception, f, A)

/* Threads */
extern int init_async(int);
extern int exit_async(void);

#define ERTS_EXIT_AFTER_DUMP _exit


#endif /* #ifndef _ERL_UNIX_SYS_H */
