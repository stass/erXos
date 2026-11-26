# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the reader of the control tree's lines, erx_bt_pair:next/1, bonds/1,
# parse/1 and parse_bond/1 (test/erlang/erx_bt_pair_fuzz.erl over the stub file
# test/erlang/erx_bt_pair_stub.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# sources as they are, then a copy of erx_bt_pair whose buffer bound is checked only at a
# newline, which must fail: an unterminated stream past bt_pair_line_max is overlong.
module ErxBtPairFuzz
  ROOT = File.expand_path('../..', __dir__)
  TREE = 'erlang/apps/erx_bt_client/src/erx_bt_pair.erl'
  FUZZ = %w[test/erlang/erx_bt_pair_fuzz.erl test/erlang/erx_bt_pair_stub.erl].freeze
  BOUND = "        [_] when byte_size(Held) > ?ERX_BT_PAIR_LINE_MAX -> overlong;\n" \
          '        [_] -> read(Reader, ?ERX_BT_PAIR_LINE_MAX + 1 - byte_size(Held))'
  SEEDED = '        [_] -> read(Reader, ?ERX_BT_PAIR_LINE_MAX + 1)'
  DEADLINE_SECONDS = '120'
  VERDICT = 'disagrees_with_model'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    tree = File.binread(File.join(ROOT, TREE))
    raise "no bound check in #{TREE}" unless tree.scan(BOUND).size == 1

    output, status = fuzz(tree, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(tree.sub(BOUND) { SEEDED }, seed: seed)
    if status.success? || !output.include?(VERDICT)
      abort("a reader that checks its bound only at a newline passed:\n#{output}")
    end
    puts 'erx_bt_pair reads within its bound at every split, ' \
         'and a reader that checks the bound only at a newline does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(tree_text, seed:)
    Dir.mktmpdir('erx-bt-pair-fuzz') do |work|
      tree_path = File.join(work, File.basename(TREE))
      File.binwrite(tree_path, tree_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work, sources: [tree_path, *FUZZ.map { |path| File.join(ROOT, path) }],
                            include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_pair_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtPairFuzz.run(seed: seed)
end
