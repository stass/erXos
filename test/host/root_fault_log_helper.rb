# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/fuzz/crash_frame'

# The serial log of a root task's fault on Fiasco, built at test time from the
# ABI file's crash record layout, so a layout change needs no recaptured log:
# the console text the test names, then the crash frame of the full record the
# Fiasco backend's end path writes in a development build (docs/design-fiasco.md, "Faults, and the
# fault of the root task"), then the reset's line. The QEMU suites native_crash
# and system_domain hold real guests' logs to the same judges.
#
# The fault words are Fiasco's, as captured from those guests, and written here
# as literals rather than through RootFault, so a wrong belief in the judge
# about Fiasco's encoding fails these tests instead of moving with them.
module RootFaultLog
  # Fiasco's fault word for a read, a write to a read-only page, and musl's
  # abort's store to address 0; the trap's word is its exception syndrome.
  READ = 0x1
  READ_ONLY_WRITE = 0x2
  ABORT_WRITE = 0x3
  TRAP = 0xf200_0001
  # The thread the root's fault gate cannot name, and the root task's space.
  THREAD_UNKNOWN = 0xffff_ffff_ffff_ffff
  ROOT_SPACE = 0
  # Any pc at or above RAM's first address is in the root's image.
  PC_ABOVE_RAM = 0x1_b944
  # The page test/guest/native_crash touches in its memory cases.
  TOUCHED = 0x40_0004_1000
  TEXT = "root task fault\n"

  module_function

  def log(kind:, cause:, pc:, address: 0, before: '')
    fault = { 'kind' => kind, 'cause' => cause, 'addr' => address, 'pc' => pc, 'thread' => THREAD_UNKNOWN, 'space' => ROOT_SPACE }
    record = Erx::CrashFrameFuzz.full_record(cause: :fault, fault: fault, text: TEXT)
    "#{before}#{Erx::CrashFrameFuzz.frame_of(record).gsub("\n", "\r\n")}erx: end reset\r\n"
  end
end
