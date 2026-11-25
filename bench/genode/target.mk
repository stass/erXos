# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# erx_peer_bench as a Genode component (docs/design-bench.md, "Genode's guest"), linked
# against Genode's C library. `tools/erx build genode` (tools/lib/erx/genode_build.rb)
# stages it as src/app/erx_peer_bench/target.mk of erXos's Genode repository, beside
# flags.mk, the program's -D flags from their one source (PeerBench.flags), and root/,
# the program's C files at their tree paths.
TARGET   = erx_peer_bench
SRC_C    = erx_peer_bench.c
LIBS     = posix libc libm
INC_DIR += $(PRG_DIR)/root
CC_OPT  += -std=c17 -O2
# Read the counter without the probe (docs/design-bench.md, "The program's clock and
# placement").
CC_OPT  += -DERX_PEER_COUNTER
include $(PRG_DIR)/flags.mk
vpath erx_peer_bench.c $(PRG_DIR)/root/bench/peer
