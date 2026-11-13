# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs PROGRAM with the file BUFFER open for reading and writing as its
# descriptor 3: on the host, the window's buffer that erx-lvgl maps, as its
# session maps the buffer's pages into it on the target
# (docs/design-display.md, "The widget server"). The model screen
# test/erlang/erx_lvgl_screen.erl starts erx-lvgl through it, since an Erlang
# port hands a program only its standard input and output.
abort 'usage: erx_lvgl_buffer.rb BUFFER PROGRAM' unless ARGV.size == 2
buffer, program = ARGV
exec(program, 3 => File.open(buffer, File::RDWR))
