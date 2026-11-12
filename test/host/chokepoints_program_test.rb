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

  # The driver alone passes handles into a program's table in ERTS; liberx's domain library
  # and a comment naming the call are not ERTS's passes.
  def test_only_the_program_driver_passes_handles_in_erts
    installs = [rule('program-installs')]
    pass = "\tstatus = erx_cap_pass(ERX_CAP_SELF, program->image, count);\n"
    allowed = {
      Rules::PROGRAM_DRIVER => pass,
      'liberx/system/dom_install.c' => "\tstatus = erx_cap_pass(ERX_CAP_SELF, recipient, 1);\n",
      'otp/erts/emulator/sys/erxos/erx_program_core.h' => "/* the install's erx_cap_pass from index first */\n"
    }
    assert_empty evaluate(installs, allowed, imported: allowed.keys.grep(/\Aotp/))
    %w[otp/erts/emulator/sys/erxos/erx_gate.c otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c].each do |path|
      refute_empty evaluate(installs, { path => pass }, imported: [path]), "#{path} may pass"
    end
  end

  # A program's frame becomes a term only in the driver, by a decode that names
  # ERTS_DIST_EXT_BTT_SAFE on its line; stock ERTS's own decodes, and a comment naming the
  # call, are not erXos's. A second decoder elsewhere, and the driver's decode without the
  # flag or with the flag on another line, fail.
  def test_only_the_program_driver_decodes_a_programs_frame_and_only_safely
    decode = [rule('program-safe-decode')]
    safe = "\tterm = erts_decode_ext(&factory, &ext, ERTS_DIST_EXT_BTT_SAFE);\n"
    allowed = {
      Rules::PROGRAM_DRIVER => safe,
      'otp/erts/emulator/beam/external.c' => "\tres = erts_decode_ext(&factory, &ext, 0);\n",
      'otp/erts/emulator/sys/erxos/erx_program_core.h' => "/* erts_decode_ext(..., 0) */\n"
    }
    assert_empty evaluate(decode, allowed, imported: allowed.keys.grep(/\Aotp/))
    refused = [
      ['otp/erts/emulator/sys/erxos/erx_lane_drv.c', safe],
      ['otp/erts/emulator/nifs/common/erx_stdio_nif.c', safe],
      ['otp/erts/emulator/sys/erxos/erx_lane_drv.c', "\tterm = erts_decode_ext\n\t    (&factory, &ext, ERTS_DIST_EXT_BTT_SAFE);\n"],
      [Rules::PROGRAM_DRIVER, "\ta = erts_decode_ext(&f, &e, 0), b = erts_decode_ext(&f, &e, ERTS_DIST_EXT_BTT_SAFE);\n"],
      [Rules::PROGRAM_DRIVER, "\tterm = erts_decode_ext(&factory, &ext, flags & ~ERTS_DIST_EXT_BTT_SAFE);\n"],
      ['otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c', safe],
      [Rules::PROGRAM_DRIVER, "\tterm = erts_decode_ext(&factory, &ext, 0);\n"],
      [Rules::PROGRAM_DRIVER, "\tterm = erts_decode_ext(&factory, &ext,\n\t    ERTS_DIST_EXT_BTT_SAFE);\n"]
    ]
    refused.each do |path, text|
      refute_empty evaluate(decode, { path => text }, imported: [path]), "#{path} may decode: #{text}"
    end
  end
end
