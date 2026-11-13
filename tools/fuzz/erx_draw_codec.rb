# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/abi'

# The fuzz target of erx_draw_codec:decode/2 and erx_draw_image:decode/3, the
# decoders of what a draw client writes, and of erx_draw_core:plan/2, which
# checks a whole write against a connection (docs/design-display.md, "Draw
# messages"). The codec is generated from abi/formats/draw.txt and run with
# test/erlang/erx_draw_codec_fuzz.erl, which draws its cases from
# test/erlang/erx_draw_codec_tests.erl, on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's).
module ErxDrawCodecFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_win/src/erx_draw_image.erl erlang/apps/erx_win/src/erx_draw_core.erl
               erlang/apps/erx_memdraw/src/erx_chan.erl test/erlang/erx_draw_codec_tests.erl test/erlang/erx_draw_core_tests.erl
               test/erlang/erx_draw_codec_fuzz.erl].map { |path| File.join(ROOT, path) }.freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    module_text = Erx::ABI::Generator.plan(root: ROOT).files.fetch(Erx::ABI::DrawEmitter::ERLANG_PATH)
    Dir.mktmpdir('erx-draw-codec-fuzz') do |work|
      module_path = File.join(work, 'erx_draw_codec.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       module_path, *SOURCES, stdin_data: '')
      abort(output) unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-run', 'erx_draw_codec_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                                       chdir: work, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxDrawCodecFuzz.run(seed: seed)
end
