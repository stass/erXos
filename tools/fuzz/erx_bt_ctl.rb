# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the control tree's ctl file, erx_bt_fs_tree:parse/1
# (test/erlang/erx_bt_ctl_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), with erx_bt_pair, whose id/1 checks a
# bond's id, so it needs no hosted build. It runs the sources as they are, then a copy
# of erx_bt_pair that takes upper-case digits in an id, which must fail: an id is
# written in lower case, and one in another case names no bond.
module ErxBtCtlFuzz
  ROOT = File.expand_path('../..', __dir__)
  TREE = 'erlang/apps/erx_bt/src/erx_bt_fs_tree.erl'
  FUZZ = 'test/erlang/erx_bt_ctl_fuzz.erl'
  PAIR = 'erlang/apps/erx_bt_client/src/erx_bt_pair.erl'
  CLAUSE = 'is_id_digit(C) -> C >= $0 andalso C =< $9 orelse C >= $a andalso C =< $f.'
  SEEDED = 'is_id_digit(C) -> C >= $0 andalso C =< $9 orelse C >= $a andalso C =< $f orelse C >= $A andalso C =< $F.'
  DEADLINE_SECONDS = '120'
  VERDICT = 'disagrees_with_writer'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    pair = File.binread(File.join(ROOT, PAIR))
    raise "no clause #{CLAUSE} in #{PAIR}" unless pair.scan(CLAUSE).size == 1

    output, status = fuzz(pair, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(pair.sub(CLAUSE, SEEDED), seed: seed)
    abort("an id check that takes upper-case digits passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts "erx_bt_fs_tree takes ctl's commands alone, and an id check that takes upper-case digits does not pass"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(pair_text, seed:)
    Dir.mktmpdir('erx-bt-ctl-fuzz') do |work|
      pair_path = File.join(work, File.basename(PAIR))
      File.binwrite(pair_path, pair_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work, sources: [File.join(ROOT, TREE), pair_path, File.join(ROOT, FUZZ)], include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_ctl_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtCtlFuzz.run(seed: seed)
end
