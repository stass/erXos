/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2002-2025. All Rights Reserved.
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
 * Modified by erXos: the initial environment is the boot information page's, not the host's.
 *
 * %CopyrightEnd%
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_osenv.h"
#include "erl_alloc.h"

#include "erl_thr_progress.h"

static erts_osenv_t sysenv_global_env;
static erts_rwmtx_t sysenv_rwmtx;

static void import_initial_env(void);

void erts_sys_env_init(void) {
    erts_rwmtx_init(&sysenv_rwmtx, "environ", NIL,
        ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_GENERIC);

    erts_osenv_init(&sysenv_global_env);
    import_initial_env();
}

const erts_osenv_t *erts_sys_rlock_global_osenv(void) {
    erts_rwmtx_rlock(&sysenv_rwmtx);
    return &sysenv_global_env;
}

erts_osenv_t *erts_sys_rwlock_global_osenv(void) {
    erts_rwmtx_rwlock(&sysenv_rwmtx);
    return &sysenv_global_env;
}

void erts_sys_rwunlock_global_osenv(void) {
    erts_rwmtx_rwunlock(&sysenv_rwmtx);
}

void erts_sys_runlock_global_osenv(void) {
    erts_rwmtx_runlock(&sysenv_rwmtx);
}

int erts_sys_explicit_8bit_putenv(char *key, char *value) {
    erts_osenv_data_t env_key, env_value;
    int result;

    env_key.length = sys_strlen(key);
    env_key.data = key;

    env_value.length = sys_strlen(value);
    env_value.data = value;

    {
        erts_osenv_t *env = erts_sys_rwlock_global_osenv();
        result = erts_osenv_put_native(env, &env_key, &env_value);
        erts_sys_rwunlock_global_osenv();
    }

    return result;
}

int erts_sys_explicit_8bit_getenv(char *key, char *value, size_t *size) {
    erts_osenv_data_t env_key, env_value;
    int result;

    env_key.length = sys_strlen(key);
    env_key.data = key;

    /* Reserve space for NUL termination. */
    env_value.length = *size - 1;
    env_value.data = value;

    {
        const erts_osenv_t *env = erts_sys_rlock_global_osenv();
        result = erts_osenv_get_native(env, &env_key, &env_value);
        erts_sys_runlock_global_osenv();
    }

    if(result == 1) {
        value[env_value.length] = '\0';
    }

    *size = env_value.length;

    return result;
}

int erts_sys_explicit_host_getenv(const char *key, char *value, size_t *size) {
    const size_t key_length = sys_strlen(key);
    const char *words;
    size_t length, used = 0;

    erx_runtime_env(&words, &length);
    while (used < length) {
        const char *word = words + used;
        const size_t word_length = sys_strlen(word);

        used += word_length + 1;
        if (word_length > key_length && word[key_length] == '='
            && memcmp(word, key, key_length) == 0) {
            const size_t value_length = word_length - key_length - 1;

            if (value_length >= *size) {
                *size = value_length + 1;
                return -1;
            }
            sys_memcpy((void*)value, (void*)(word + key_length + 1), value_length + 1);
            *size = value_length;
            return 1;
        }
    }
    return 0;
}

static void import_initial_env(void) {
    const char *words;
    size_t length, used = 0;

    erx_runtime_env(&words, &length);
    while (used < length) {
        const char *word = words + used;
        const size_t word_length = sys_strlen(word);
        const char *separator = strchr(word, '=');
        erts_osenv_data_t env_key, env_value;

        env_key.length = separator - word;
        env_key.data = (void*)word;
        env_value.length = word_length - env_key.length - 1;
        env_value.data = (void*)(separator + 1);
        erts_osenv_put_native(&sysenv_global_env, &env_key, &env_value);
        used += word_length + 1;
    }
}
