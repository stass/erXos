# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# Builds lwip_bench, the benchmark client of tools/erx bench net-freebsd, on the
# host that runs it.  LWIP and CONTRIB name the unpacked, hash-verified lwIP
# 2.2.1 and lwIP contrib 2.1.0 trees; tapif.c is contrib's tap interface with
# tapif-freebsd.patch applied (the tap device named by $TAPDEV, and runt frames
# padded to the Ethernet minimum).  The file lists are lwIP's own
# (Filelists.mk), which only GNU make reads: gmake on FreeBSD.

LWIP = lwip-2.2.1
CONTRIB = contrib-2.1.0
LWIPDIR = $(LWIP)/src
include $(LWIPDIR)/Filelists.mk
CC = cc
CFLAGS = -O2 -Wall -DLWIP_NOASSERT_ON_ERROR
SOURCES = lwip_bench.c tapif.c $(COREFILES) $(CORE4FILES) $(LWIPDIR)/netif/ethernet.c

lwip_bench: lwipopts.h $(SOURCES)
	$(CC) $(CFLAGS) -I. -I$(LWIPDIR)/include -I$(CONTRIB)/ports/unix/port/include -o $@ $(SOURCES)

tapif.c: tapif-freebsd.patch
	patch -o $@ $(CONTRIB)/ports/unix/port/netif/tapif.c tapif-freebsd.patch
