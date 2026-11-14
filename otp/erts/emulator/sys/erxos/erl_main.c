/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2000-2025. All Rights Reserved.
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
 * Modified by erXos: ERTS starts on the boot information page, whose entry owns main,
 * reads the startup limits from it, gives ERTS the flags of its limits and grant and refuses
 * arguments that raise them, and maps the domain's crash area.
 *
 * %CopyrightEnd%
 */
#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif
#include "sys.h"
#include "erl_vm.h"
#include "global.h"

#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/runtime_entry.h"
#include "erx_crash_area.h"

static erx_boot_view_t boot_view;
/* The vector's plan, whose ERTS limits erx_runtime_settings_check holds the arguments to. */
static erx_boot_argv_plan_t argv_plan;

void
erx_runtime_env(const char **words, size_t *length)
{
    *words = boot_view.env;
    *length = boot_view.info.env_len;
}

/* The startup limits' cap of the domain's /tmp, in bytes (docs/design-tmp.md). */
uint64_t
erx_runtime_tmp_limit(void)
{
    return boot_view.info.limits.tmp;
}

const struct erx_boot_info *
erx_runtime_boot(void)
{
    return &boot_view.info;
}

/* The system connection's peer node name, in the page, and its length: 0 in the system domain. */
const char *
erx_runtime_system_node(size_t *length)
{
    *length = boot_view.info.system_connection.peer_node_len;
    return boot_view.system_node;
}

int
erx_runtime_framebuffer(struct erx_boot_framebuffer *out)
{
    return erx_boot_framebuffer(&boot_view, out);
}

const struct erx_runtime_limits *
erx_runtime_limits(void)
{
    return &boot_view.info.limits;
}

/* The system domain is the root task (docs/design-runtime.md, "The root-task entry"). */
int
erx_runtime_is_system(void)
{
    return (boot_view.info.flags & ERX_BOOT_ROOT) != 0;
}

/*
 * Once erl_start has read its arguments: none may raise what the page's flags gave, the
 * startup limits' tables and the grant's schedulers (docs/design-runtime.md, "Starting a
 * runtime"). A raised one ends the start, as ERTS ends it on a flag out of its range.
 */
void
erx_runtime_settings_check(int processes, int atoms, int schedulers, int online)
{
    const erx_boot_erts_settings_t settings = {
        .processes = processes, .atoms = atoms, .schedulers = schedulers, .online = online,
    };
    const char *reason = erx_boot_erts_admit(&argv_plan.limits, &settings);

    if (reason != NULL) {
        erts_fprintf(stderr, "erx: the emulator flags: %s\n", reason);
        erts_exit(1, "");
    }
}

/*
 * erl_start reads its arguments as emulator flags, --, then init's arguments, and edits
 * the vector, which is why the page's words are copied. The flags of the page's limits
 * come first, so a flag of the page's own after them lowers a setting. See
 * docs/design-runtime.md, "Configuration".
 */
void
erx_runtime_main(void)
{
    erx_boot_info_status_t status;
    const char *reason;
    char **argv;
    char *strings;

    status = erx_boot_info_read(erx_boot_info(), ERX_PAGE_SIZE, &boot_view);
    if (status != ERX_BOOT_INFO_OK) {
        fprintf(stderr, "erx: the boot information page: %s\n", erx_boot_info_reason(status));
        exit(1);
    }
    erx_crash_area_init();
    reason = erx_boot_argv_plan(&boot_view, &argv_plan);
    if (reason != NULL) {
        fprintf(stderr, "erx: %s\n", reason);
        exit(1);
    }
    argv = malloc((argv_plan.argc + 1) * sizeof(*argv));
    strings = malloc(argv_plan.strings);
    if (argv == NULL || strings == NULL) {
        fprintf(stderr, "erx: no memory for the arguments\n");
        exit(1);
    }
    erx_boot_argv_fill(&boot_view, &argv_plan, argv, strings);
#ifdef ERX_TRACE_START
    fprintf(stderr, "erx: erts: erl_start runs, %zu arguments\n", argv_plan.argc);
#endif
    erl_start((int) argv_plan.argc, argv);
}
