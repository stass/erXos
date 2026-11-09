# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# Builds the tap helper erx_net_tap into erx_net's priv/ with the host's own C
# compiler, on the host it runs on: `make -C c_src`. It is never built for
# erXos's target. POSIX make, so BSD make and GNU make both read it. PRIV
# names another output directory; CFLAGS adds flags, such as -Werror, ahead of
# the helper's own, so a make's default -O cannot override them.

.POSIX:

CC = cc
PRIV = ../priv
ERX_CFLAGS = -std=c17 -O2 -Wall -Wextra -Wpedantic

all: $(PRIV)/erx_net_tap

$(PRIV)/erx_net_tap: erx_net_tap.c
	mkdir -p "$(PRIV)"
	$(CC) $(CFLAGS) $(ERX_CFLAGS) -o "$@" erx_net_tap.c

clean:
	rm -f "$(PRIV)/erx_net_tap"
