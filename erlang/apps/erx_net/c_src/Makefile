# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# Builds erx_net's native parts into its priv/ with the host's own C compiler,
# on the host they run on: `make -C c_src`, or one of them by its target name.
# * nif: erx_bytes_nif.so, the per-byte primitives of the portable erx_bytes
#   (portable/erx_bytes.erl), against the headers of the emulator that ERL
#   runs, the one that will load it. Its cores, erx_inet_csum.c and
#   erx_siphash.c, and their NIF functions, erx_net_bytes.c, are also linked
#   statically into erXos's ERTS, whose build compiles them from here.
# * tap: erx_net_tap, the tap helper, a port program. It is never built for
#   erXos's target.
# POSIX make, so BSD make and GNU make both read it. The recipe asks uname how
# to link a loadable module, the one thing that differs between hosts.
# PRIV names another output directory; CFLAGS adds flags, such as -Werror,
# ahead of erx_net's own, so a make's default -O cannot override them.

.POSIX:

CC = cc
ERL = erl
PRIV = ../priv
ERX_CFLAGS = -std=c17 -O2 -Wall -Wextra -Wpedantic
NIF_SOURCES = erx_bytes_nif.c erx_net_bytes.c erx_inet_csum.c erx_siphash.c
NIF_HEADERS = erx_net_bytes.h erx_inet_csum.h erx_siphash.h

all: nif tap

nif: $(PRIV)/erx_bytes_nif.so

tap: $(PRIV)/erx_net_tap

$(PRIV)/erx_bytes_nif.so: $(NIF_SOURCES) $(NIF_HEADERS)
	mkdir -p "$(PRIV)"
	include=`$(ERL) -noshell -eval 'io:format("~ts", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "include"])]), halt().'` && \
	{ test -f "$$include/erl_nif.h" || { echo "c_src: no erl_nif.h in $$include (ERL=$(ERL))" >&2; exit 1; }; } && \
	case `uname -s` in Darwin) module="-bundle -undefined dynamic_lookup" ;; *) module="-shared" ;; esac && \
	$(CC) $(CFLAGS) $(ERX_CFLAGS) -fPIC -I"$$include" $$module -o "$@" $(NIF_SOURCES)

$(PRIV)/erx_net_tap: erx_net_tap.c
	mkdir -p "$(PRIV)"
	$(CC) $(CFLAGS) $(ERX_CFLAGS) -o "$@" erx_net_tap.c

clean:
	rm -f "$(PRIV)/erx_bytes_nif.so" "$(PRIV)/erx_net_tap"
