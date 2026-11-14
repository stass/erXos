// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The handle sigma0's static constructors pass to __cxa_atexit. The link
// takes no compiler runtime start object, which is where a program usually
// gets it. sigma0 never exits, so the registered destructors never run; the
// handle only has to exist, and to name this program, as the start object's
// own definition does (the value is its own address, the symbol hidden).

__attribute__((visibility("hidden")))
void *__dso_handle = &__dso_handle;
