# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/abi'

# The fuzz target of erx_web_proto:decode/2, the web domain's decoder of what
# a browser sends (docs/design-web.md, "Verification and testing"). The module
# is generated from abi/protocols/web.txt and run with
# test/erlang/erx_web_proto_fuzz.erl and the random messages of
# test/erlang/erx_web_proto_tests.erl on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's).
module ErxWebProtoFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[test/erlang/erx_web_proto_tests.erl test/erlang/erx_web_proto_fuzz.erl].map { |path| File.join(ROOT, path) }
  DEADLINE_SECONDS = '600'

  module_function

  def run(seed:)
    module_text = Erx::ABI::Generator.plan(root: ROOT).files.fetch(Erx::ABI::WebEmitter::ERLANG_PATH)
    Dir.mktmpdir('erx-web-proto-fuzz') do |work|
      module_path = File.join(work, 'erx_web_proto.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       module_path, *SOURCES, stdin_data: '')
      abort(output) unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-run', 'erx_web_proto_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                                       chdir: work, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxWebProtoFuzz.run(seed: seed)
end
