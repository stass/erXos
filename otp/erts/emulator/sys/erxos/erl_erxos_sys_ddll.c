/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2006-2025. All Rights Reserved.
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

/*
 * Modified by erXos: no library is ever opened. A NIF comes linked into the runtime image
 * (erts_static_nif_tab), so this layer calls a linked NIF's init function and refuses every
 * load with an error, the host's dynamic linker out of reach.
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"

#define LOAD_REFUSED "only NIFs linked into the runtime image load"

/* erl_nif reads the error's text, and erl_bif_ddll, which passes no error, reads the code. */
static int refuse(ErtsSysDdllError *err)
{
    if (err != NULL) {
        erts_sys_ddll_free_error(err);
        err->str = erts_alloc(ERTS_ALC_T_DDLL_TMP_BUF, sizeof(LOAD_REFUSED));
        sys_memcpy(err->str, LOAD_REFUSED, sizeof(LOAD_REFUSED));
    }
    return ERL_DE_ERROR_NO_DDLL_FUNCTIONALITY;
}

void erl_sys_ddll_init(void)
{
}

int erts_sys_ddll_open(const char *full_name, void **handle, ErtsSysDdllError *err)
{
    (void) full_name;
    (void) handle;
    return refuse(err);
}

int erts_sys_ddll_open_noext(char *dlname, void **handle, ErtsSysDdllError *err)
{
    (void) dlname;
    (void) handle;
    return refuse(err);
}

int erts_sys_ddll_sym2(void *handle, const char *func_name, void **function, ErtsSysDdllError *err)
{
    (void) handle;
    (void) func_name;
    (void) function;
    return refuse(err);
}

int erts_sys_ddll_vsym2(void *handle, const char *func_name, const char *vers, void **function,
                        ErtsSysDdllError *err)
{
    (void) handle;
    (void) func_name;
    (void) vers;
    (void) function;
    return refuse(err);
}

int erts_sys_ddll_load_driver_init(void *handle, void **function)
{
    (void) handle;
    (void) function;
    return refuse(NULL);
}

int erts_sys_ddll_load_nif_init(void *handle, void **function, ErtsSysDdllError *err)
{
    (void) handle;
    (void) function;
    return refuse(err);
}

void *erts_sys_ddll_call_init(void *function)
{
    void *(*initfn)(void) = function;

    return (*initfn)();
}

void *erts_sys_ddll_call_nif_init(void *function)
{
    return erts_sys_ddll_call_init(function);
}

int erts_sys_ddll_close2(void *handle, ErtsSysDdllError *err)
{
    (void) handle;
    return refuse(err);
}

char *erts_sys_ddll_error(int code)
{
    (void) code;
    return LOAD_REFUSED;
}

void erts_sys_ddll_free_error(ErtsSysDdllError *err)
{
    if (err->str != NULL) {
        erts_free(ERTS_ALC_T_DDLL_TMP_BUF, err->str);
        err->str = NULL;
    }
}
