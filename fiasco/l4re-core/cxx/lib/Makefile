# Modified by erXos: the start library (cxx_atexit), which no erXos build links
# and which alone needed libstdc++-v3's headers, is not built or imported.
PKGDIR	= ..
L4DIR	?= $(PKGDIR)/../../..
TARGET	= io base be util tl ipc

include $(L4DIR)/mk/subdir.mk

base: io
be: io
util: io
ipc: base tl

