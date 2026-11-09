# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# Builds erx-lvgl for the host: LVGL's sources from the submodule, the
# generated reader and writer of ui.txt's binary form, and erx_lvgl.c.
# tools/lib/erx/lvgl.rb runs it with every variable set; objects go under
# OUT, so the submodule's tree is never written. Each object's headers are
# recorded in a .d file beside it, so a change to an LVGL header rebuilds
# what includes it.
#
#   LVGL     LVGL's tree, the submodule display/lvgl/lvgl
#   GEN      build/gen, holding include/erx/ui_wire.h and the C source
#   OUT      the output directory
#   CC       the host C compiler
#   SANITIZE the sanitizer flags, or nothing

HERE := $(dir $(lastword $(MAKEFILE_LIST)))

LVGL_SOURCES := $(shell find $(LVGL)/src -name '*.c' -type f)
LVGL_OBJECTS := $(patsubst $(LVGL)/%.c,$(OUT)/lvgl/%.o,$(LVGL_SOURCES))

COMMON := -std=c17 -g -O1 -MMD -MP $(SANITIZE) -DLV_CONF_INCLUDE_SIMPLE -I$(HERE) -I$(LVGL)
LVGL_CFLAGS := $(COMMON) -w
OWN_CFLAGS := $(COMMON) -Wall -Wextra -Werror -I$(GEN)/include

$(OUT)/erx-lvgl: $(OUT)/erx_lvgl.o $(OUT)/erx_ui_wire.o $(OUT)/liblvgl.a
	$(CC) $(SANITIZE) -o $@ $(OUT)/erx_lvgl.o $(OUT)/erx_ui_wire.o $(OUT)/liblvgl.a -lm

$(OUT)/liblvgl.a: $(LVGL_OBJECTS)
	rm -f $@
	ar rcs $@ $(LVGL_OBJECTS)

$(OUT)/lvgl/%.o: $(LVGL)/%.c $(HERE)lv_conf.h
	@mkdir -p $(dir $@)
	$(CC) $(LVGL_CFLAGS) -c $< -o $@

$(OUT)/erx_lvgl.o: $(HERE)erx_lvgl.c $(HERE)lv_conf.h $(GEN)/include/erx/ui_wire.h
	@mkdir -p $(OUT)
	$(CC) $(OWN_CFLAGS) -c $< -o $@

$(OUT)/erx_ui_wire.o: $(GEN)/display/generated/erx_ui_wire.c $(GEN)/include/erx/ui_wire.h
	@mkdir -p $(OUT)
	$(CC) $(OWN_CFLAGS) -c $< -o $@

-include $(LVGL_OBJECTS:.o=.d) $(OUT)/erx_lvgl.d $(OUT)/erx_ui_wire.d
