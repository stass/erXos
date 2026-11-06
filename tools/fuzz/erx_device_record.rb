# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_device_record:find/3, the parse of the device records that the boot
# information carries to init's arguments, compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# module as it is, then a copy that reads a line as 64 bits wide, which must fail: that shows
# the reference holds each field to its width.
module ErxDeviceRecordFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_device_record.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_device_record_fuzz.erl')
  LINE_WIDTH = 'number(Line, 32)'
  LINE_TOO_WIDE = 'number(Line, 64)'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no line width in #{MODULE_SOURCE}" unless source.include?(LINE_WIDTH)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(LINE_WIDTH, LINE_TOO_WIDE), seed: seed)
    abort("reading a line as 64 bits wide passed:\n#{output}") if status.success? ||
                                                                 !output.include?('disagrees_with_reference')
    puts 'erx_device_record:find/3 agrees with its reference, and reading a line as 64 bits wide does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-device-record-fuzz') do |work|
      module_path = File.join(work, 'erx_device_record.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_device_record_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxDeviceRecordFuzz.run(seed: seed)
end
