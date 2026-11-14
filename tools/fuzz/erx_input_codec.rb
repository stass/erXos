# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/abi'

# The fuzz target of erx_input_codec:decode/1, the reader of the records a driver in
# another domain serves as a file, and of valid/1 and encode/1 (docs/design-abi.md,
# "Input records"). The codec is generated from abi/formats/input.txt and run with
# test/erlang/erx_input_codec_fuzz.erl on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's).
module ErxInputCodecFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = [File.join(ROOT, 'test/erlang/erx_input_codec_fuzz.erl')].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    module_text = Erx::ABI::Generator.plan(root: ROOT).files.fetch(Erx::ABI::InputEmitter::ERLANG_PATH)
    Dir.mktmpdir('erx-input-codec-fuzz') do |work|
      module_path = File.join(work, 'erx_input_codec.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-Werror',
                                       '-o', work, module_path, *SOURCES, stdin_data: '')
      abort(output) unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-run', 'erx_input_codec_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                                       chdir: work, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxInputCodecFuzz.run(seed: seed)
end
