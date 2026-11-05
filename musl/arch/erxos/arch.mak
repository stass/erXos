# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# The erxos arch layers on a CPU's arch: arch/aarch64's headers and assembly stay,
# and this directory's files replace the few that assume Linux. The files of
# ERX_SEAM_OBJS see liberx's declarations, so they rebuild when those change:
# ERX_ROOT is the erXos tree, and ERX_COMPILER_INCLUDE holds the compiler's
# <stdatomic.h>, which musl does not offer. erXos's own files keep erXos's warnings,
# less the one musl's internal headers trip.
ARCH_CPU = aarch64

ERX_SEAM_OBJS = obj/src/internal/erxos/syscall.o obj/src/thread/erxos/clone.o obj/src/thread/erxos/pthread_create_executor.o
ERX_SEAM_HEADERS = $(ERX_ROOT)/include/erx/abi.h $(wildcard $(ERX_ROOT)/liberx/backend/fiasco/*.h)
$(ERX_SEAM_OBJS): $(ERX_SEAM_HEADERS)
$(ERX_SEAM_OBJS): CFLAGS_ALL += -I$(ERX_ROOT) -I$(ERX_ROOT)/include -isystem $(ERX_COMPILER_INCLUDE)

ERX_OWN_OBJS = $(addsuffix /erxos/%.o,obj/src/internal obj/src/thread obj/src/signal obj/src/process)
$(filter $(ERX_OWN_OBJS),$(ALL_OBJS)): CFLAGS_ALL += -Wall -Wextra -Werror -Wno-unused-parameter
