#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs test/erlang/erx_grep_re_fuzz.erl, the fuzz target of grep's pattern
# translator (erlang/apps/erx_shell/src/erx_grep_re.erl, docs/design-shell.md,
# "Text commands"), against the translator as it is and against copies with
# a seeded fault, each of which must fail it: a bound of 8 KiB, a literal
# written raw, and an escaped letter such as `\d` passed through to `re`.

require 'open3'
require 'optparse'
require 'tmpdir'

module ErxGrepReFuzz
  ROOT = File.expand_path('../..', __dir__)
  TRANSLATOR_SOURCE = File.join(ROOT, 'erlang/apps/erx_shell/src/erx_grep_re.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_grep_re_fuzz.erl')
  DEADLINE_SECONDS = '300'
  PASSED = /^fuzz: \d+ inputs ok$/

  Fault = Data.define(:what, :anchor, :replacement, :markers)

  FAULTS = [
    Fault.new(what: 'a translator whose bound is 8 KiB', anchor: '-define(MAX_PATTERN, 4096).',
              replacement: '-define(MAX_PATTERN, 8192).', markers: %w[over_size_accepted]),
    Fault.new(what: 'a translator that writes a literal byte raw',
              anchor: 'literal(C) -> iolist_to_binary(io_lib:format("\\\\x~2.16.0B", [C])).',
              replacement: 'literal(C) -> <<C>>.', markers: %w[compile_failed start_option not_ascii]),
    Fault.new(what: 'a translator that passes an escaped letter through',
              anchor: 'none when C >= $a, C =< $z; C >= $A, C =< $Z -> refuse(<<"trailing backslash (\\\\)">>);',
              replacement: 'none when C >= $a, C =< $z; C >= $A, C =< $Z -> {char, [$\\\\, C], Rest, P};',
              markers: %w[raw_escape compile_failed])
  ].freeze

  module_function

  def run(seed:)
    text = File.binread(TRANSLATOR_SOURCE)
    output, status = fuzz(text, seed: seed)
    abort(output) unless status.success? && output.match?(PASSED)
    FAULTS.each do |fault|
      raise "no #{fault.anchor} in erx_grep_re" unless text.include?(fault.anchor)

      output, = fuzz(text.sub(fault.anchor) { fault.replacement }, seed: seed)
      abort("#{fault.what} passed:\n#{output}") if output.match?(PASSED) || fault.markers.none? { |marker| output.include?(marker) }
    end
    puts 'erx_grep_re translates or refuses every pattern within its bound into a source re compiles, ' \
         'and none of a translator with twice the bound, one writing literals raw or one passing `\d` through does'
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(translator_text, seed:)
    Dir.mktmpdir('erx-grep-re-fuzz') do |work|
      translator = File.join(work, 'erx_grep_re.erl').tap { |path| File.binwrite(path, translator_text) }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, translator, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_grep_re_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxGrepReFuzz.run(seed: seed)
end
