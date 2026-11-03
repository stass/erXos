# Modified by erXos: build only the bootstrap's plain static library.
PKGDIR          ?= ../..
L4DIR           ?= $(PKGDIR)/../..

TARGET          := libfdt.a libfdt.p.a
SYSTEMS         = $(SYSTEMS_PLAIN)
SRC_C           = $(LIBFDT_SRCS)
PRIVATE_INCDIR  = $(SRC_DIR)/../contrib
CONTRIB_INCDIR  = libfdt
WARNINGS        = $(WARNINGS_MEDIUM)

vpath %.c $(SRC_DIR)/../contrib

all::

include $(PKGDIR)/lib/contrib/Makefile.libfdt
include $(L4DIR)/mk/lib.mk
