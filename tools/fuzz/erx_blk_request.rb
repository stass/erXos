# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the block driver's parse of what a device wrote,
# erx_blk_request:decode/2, and of its request checks, compiled from source and run alone
# on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It
# runs the module as it is, then a copy that accepts a read completion longer than the
# request, which must fail: that shows the reference holds a completion to its exact size.
module ErxBlkRequestFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_request.erl')
  SOURCES = [File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_write.erl'),
             File.join(ROOT, 'test/erlang/erx_blk_request_fuzz.erl')].freeze
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')
  EXACT = '<<Data:Size/binary, Status:8>> ->'
  TOO_LONG = '<<Data:Size/binary, Status:8, _/binary>> ->'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no exact read completion in #{MODULE_SOURCE}" unless source.include?(EXACT)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(EXACT, TOO_LONG), seed: seed)
    abort("accepting a long read completion passed:\n#{output}") if status.success? ||
                                                                     !output.include?('disagrees_with_reference')
    puts 'erx_blk_request:decode/2 agrees with its reference, and accepting a long completion does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-blk-request-fuzz') do |work|
      module_path = File.join(work, 'erx_blk_request.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, *SOURCES, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_blk_request_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxBlkRequestFuzz.run(seed: options.fetch(:seed))
end
