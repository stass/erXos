# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsProgramTest < Minitest::Test
  include ChokepointsHelper

  CREATE = "\tstatus = erx_space_create(budget, ERX_CAP_SELF, gate, label, 0, 16, &anchor);\n"
  CALLS = {
    'create' => CREATE,
    'map' => "\tstatus = erx_image_map(image, release, index, &pc);\n",
    'thread' => "\tstatus = erx_thread_create(budget, image, group, 0, &thread);\n",
    'stop' => "\t(void)erx_space_stop(anchor, status);\n"
  }.freeze

  # The driver makes and stops a program's spaces; any other ERTS source is refused,
  # while the crash path's stop of the runtime's own space, liberx's own callers and a
  # comment naming a call are not a program's.
  def test_only_the_program_driver_makes_a_programs_spaces_in_erts
    program = [rule('program-spaces')]
    allowed = {
      Rules::PROGRAM_DRIVER => CALLS.values.join,
      'otp/erts/emulator/sys/erxos/erx_crash_area.c' => "\t(void) erx_space_stop(ERX_CAP_SELF, ERX_EXIT_CRASH);\n",
      'liberx/system/dom_apply.c' => CREATE,
      'otp/erts/emulator/sys/erxos/erx_program_core.h' => "/* erx_space_stop(anchor, status) */\n"
    }
    assert_empty evaluate(program, allowed, imported: allowed.keys.grep(/\Aotp/))
    CALLS.each do |call, line|
      %w[otp/erts/emulator/sys/erxos/erx_gate.c otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c].each do |path|
        refute_empty evaluate(program, { path => line }, imported: [path]), "#{path} may #{call}"
      end
    end
  end
end
