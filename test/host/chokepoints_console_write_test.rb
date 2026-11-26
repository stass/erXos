# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The dispatch-console-write rule's own cases on Fiasco's glue: the console
# ring, beside the stop's polled write, provides the cores' console write, and
# any other glue file, the stop's among them, that names it is refused.
class ChokepointsConsoleWriteTest < Minitest::Test
  include ChokepointsHelper

  WRITE = "extern \"C\" void\nerx_effect_console_write(char const *line, size_t length)\n" \
          "{\n  Erx_console_ring::write_uart(line, length);\n}\n"
  CALL = "static void f() { erx_effect_console_write(\"x\", 1); }\n"

  def found(path, text) = evaluate([rule('dispatch-console-write')], { path => text })

  def test_the_console_ring_provides_the_write
    assert_empty found('fiasco/kernel/src/erx/erx_console_ring.cpp', WRITE)
  end

  def test_other_glue_is_refused
    %w[fiasco/kernel/src/erx/erx_machine_stop.cpp fiasco/kernel/src/erx/erx_clock.cpp].each do |path|
      refute_empty found(path, CALL), path
      refute_empty found(path, WRITE), path
    end
  end
end
