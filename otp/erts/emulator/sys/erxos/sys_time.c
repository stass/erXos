/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2005-2025. All Rights Reserved.
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
 * Modified by erXos: both of ERTS's clocks are liberx's. The stock file's choice among
 * operating-system clocks and their workarounds is gone.
 *
 * %CopyrightEnd%
 */

/*
 * The operating system's clocks, as ERTS's time supervisor asks for them. Monotonic time
 * is erx_clock_ns and system time erx_time_wall_ns, which moves with it by one offset, so
 * the supervisor's correction between the two finds nothing to correct.
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include <stdlib.h>
#include "sys.h"
#include "global.h"

#include "liberx/backend/api.h"
#include "liberx/backend/runtime_entry.h"

#define NS_PER_S ((Uint64) 1000*1000*1000)

ErtsSysTimeData__ erts_sys_time_data__ erts_align_attribute(ERTS_CACHE_LINE_SIZE);

void
sys_init_time(ErtsSysInitTimeResult *init_resp)
{
    init_resp->have_os_monotonic_time = 1;
    init_resp->have_corrected_os_monotonic_time = 0;
    init_resp->os_monotonic_time_unit = ERTS_COMPILE_TIME_MONOTONIC_TIME_UNIT;
    init_resp->sys_clock_resolution = SYS_CLOCK_RESOLUTION;

    /* The resolution each reports is its unit: the backends do not say how fine their clocks tick. */
    init_resp->os_monotonic_time_info.func = "erx_clock_ns";
    init_resp->os_monotonic_time_info.clock_id = NULL;
    init_resp->os_monotonic_time_info.resolution = NS_PER_S;
    init_resp->os_monotonic_time_info.locked_use = 0;

    init_resp->os_system_time_info.func = "erx_time_wall_ns";
    init_resp->os_system_time_info.clock_id = NULL;
    init_resp->os_system_time_info.resolution = NS_PER_S;
    init_resp->os_system_time_info.locked_use = 0;

    erts_sys_time_data__.r.o.perf_counter = erts_sys_hrtime;
    erts_sys_time_data__.r.o.perf_counter_unit = ERTS_HRTIME_UNIT;
}

void
erts_late_sys_init_time(void)
{
}

ErtsMonotonicTime
erts_os_monotonic_time(void)
{
    return (ErtsMonotonicTime) erx_clock_ns();
}

ErtsSystemTime
erts_os_system_time(void)
{
    uint64_t wall_ns;

    if (!erx_time_wall_ns(&wall_ns))
        erts_exit(ERTS_ABORT_EXIT, "erx_time_wall_ns: wall time is unavailable\n");
    return (ErtsSystemTime) wall_ns;
}

void
erts_os_times(ErtsMonotonicTime *mtimep, ErtsSystemTime *stimep)
{
    *mtimep = erts_os_monotonic_time();
    *stimep = erts_os_system_time();
}

ErtsSysHrTime
erts_sys_hrtime(void)
{
    return (ErtsSysHrTime) erx_clock_ns();
}

void
sys_gettimeofday(SysTimeval *tv)
{
    const ErtsSystemTime ns = erts_os_system_time();

    tv->tv_sec = (time_t) (ns / 1000000000);
    tv->tv_usec = (suseconds_t) ((ns % 1000000000) / 1000);
}

/*
 * A group's CPU usage: erx_group_info's, where a backend measures it. No backend does
 * (docs/design-stopgap.md, "The hosted backend"), so statistics(runtime) fails with notsup
 * rather than answer with a made-up value.
 */
int
erts_sys_cpu_time_ms(ErtsMonotonicTime *user, ErtsMonotonicTime *sys)
{
    (void) user;
    (void) sys;
    return 0;
}
