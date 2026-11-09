# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/abi'

# The fuzz target of erx_ui_schema:validate/2, the validator of the widget trees a
# client sends (docs/design-display.md, "Verification and testing"). The module is
# generated from abi/formats/ui.txt and run with test/erlang/erx_ui_schema_fuzz.erl
# alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's).
module ErxUISchemaFuzz
  ROOT = File.expand_path('../..', __dir__)
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_ui_schema_fuzz.erl')
  DEADLINE_SECONDS = '300'
  MODULES = [Erx::ABI::UIEmitter::ERLANG_PATH, Erx::ABI::InspectionEmitter::ERLANG_PATH,
             Erx::ABI::PresentEmitter::ERLANG_PATH].freeze

  module_function

  def run(seed:)
    files = Erx::ABI::Generator.plan(root: ROOT).files
    Dir.mktmpdir('erx-ui-schema-fuzz') do |work|
      # The validator checks a presentation with erx_present, which reads paths with erx_schema.
      modules = MODULES.map do |path|
        File.join(work, File.basename(path)).tap { |module_path| File.binwrite(module_path, files.fetch(path)) }
      end
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       *modules, TARGET_SOURCE, stdin_data: '')
      abort(output) unless status.success?

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-run', 'erx_ui_schema_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                                       chdir: work, stdin_data: '')
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      puts output
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxUISchemaFuzz.run(seed: seed)
end
