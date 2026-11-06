# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the command shell's tokenizer and parser, erx_shell_lex and
# erx_shell_parse (test/erlang/erx_shell_parse_fuzz.erl), compiled from source and run
# on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the modules as they
# are, then a copy of the parser that allows one level more than 256, which the
# target's 257-level nestings must catch, and a copy of the tokenizer that reads one
# byte more than 64 KiB, which its 65,537-byte source must catch, and a copy of the
# parser that does not count `$` as a level, which the target's own level walker must
# catch: that shows the target reaches both bounds and checks the level count (docs/design-shell.md, "Verification and testing").
module ErxShellParseFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCE_DIR = File.join(ROOT, 'erlang/apps/erx_shell/src')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_shell_parse_fuzz.erl')
  DEPTH = '-define(MAX_DEPTH, 256).'
  DEEPER = '-define(MAX_DEPTH, 257).'
  BYTES = '-define(MAX_BYTES, 65536).'
  LONGER = '-define(MAX_BYTES, 65537).'
  DEADLINE_SECONDS = '300'

  Fault = Data.define(:what, :module_name, :anchor, :replacement, :markers)

  FAULTS = [
    Fault.new(what: 'a parser allowing 257 levels', module_name: 'erx_shell_parse',
              anchor: DEPTH, replacement: DEEPER, markers: %w[too_deep_accepted]),
    Fault.new(what: 'a tokenizer reading 65,537 bytes', module_name: 'erx_shell_lex',
              anchor: BYTES, replacement: LONGER, markers: %w[over_size_accepted]),
    Fault.new(what: 'a parser that does not count `$`', module_name: 'erx_shell_parse',
              anchor: "part([{dollar, At, _} | Tokens], D) ->\n    D1 = enter(D, At),",
              replacement: "part([{dollar, _At, _} | Tokens], D) ->\n    D1 = D,", markers: %w[wrong_levels too_deep_accepted])
  ].freeze

  module_function

  def run(seed:)
    sources = %w[erx_shell_lex erx_shell_parse].to_h { |name| [name, File.binread(File.join(SOURCE_DIR, "#{name}.erl"))] }
    output, status = fuzz(sources, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ inputs ok$/)
    FAULTS.each do |fault|
      text = sources.fetch(fault.module_name)
      raise "no #{fault.anchor} in #{fault.module_name}" unless text.include?(fault.anchor)

      output, status = fuzz(sources.merge(fault.module_name => text.sub(fault.anchor, fault.replacement)), seed: seed)
      abort("#{fault.what} passed:\n#{output}") if output.match?(/^fuzz: \d+ inputs ok$/) || fault.markers.none? { |marker| output.include?(marker) }
    end
    puts 'erx_shell_parse parses or diagnoses every input within its bounds, and none of a parser allowing ' \
         '257 levels, a tokenizer reading 65,537 bytes or a parser not counting `$` does'
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(sources, seed:)
    Dir.mktmpdir('erx-shell-parse-fuzz') do |work|
      paths = sources.map do |name, text|
        File.join(work, "#{name}.erl").tap { |path| File.binwrite(path, text) }
      end
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *paths, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_shell_parse_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxShellParseFuzz.run(seed: seed)
end
