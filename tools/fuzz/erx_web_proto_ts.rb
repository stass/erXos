# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require_relative '../lib/erx/web_stage'

# The fuzz target of the web client's decoder of the web protocol,
# web/src/generated/proto.ts (docs/design-web.md, "Verification and testing"):
# web/test/proto_fuzz.ts under Node, from the staged web tree.
module ErxWebProtoTSFuzz
  ROOT = File.expand_path('../..', __dir__)
  ROUNDS = 200_000
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    Erx::WebStage.with(root: ROOT) do |stage|
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, *Erx::WebStage::NODE,
                                       'test/proto_fuzz.ts', seed.to_s, ROUNDS.to_s, chdir: stage, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxWebProtoTSFuzz.run(seed: seed)
end
