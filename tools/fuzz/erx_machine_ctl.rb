# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the machine tree's ctl file, erx_machine_fs:parse/1
# (test/erlang/erx_machine_ctl_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs
# the sources as they are, then a copy of erx_machine_fs that also takes `trial`, which
# must fail: a session's write would then ask for the update service's end.
module ErxMachineCtlFuzz
  ROOT = File.expand_path('../..', __dir__)
  TREE = 'erlang/apps/erx_domain/src/erx_machine_fs.erl'
  FUZZ = 'test/erlang/erx_machine_ctl_fuzz.erl'
  CLAUSE = 'parse(<<"off">>) -> {ok, off};'
  SEEDED = "parse(<<\"trial\">>) -> {ok, reset};\n#{CLAUSE}".freeze
  DEADLINE_SECONDS = '120'
  VERDICT = 'disagrees_with_writer'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    tree = File.binread(File.join(ROOT, TREE))
    raise "no clause #{CLAUSE} in #{TREE}" unless tree.scan(CLAUSE).size == 1

    output, status = fuzz(tree, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(tree.sub(CLAUSE, SEEDED), seed: seed)
    abort("a parse that takes trial passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_machine_fs takes reset and off alone, and a parse that also takes trial does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(tree_text, seed:)
    Dir.mktmpdir('erx-machine-ctl-fuzz') do |work|
      tree_path = File.join(work, File.basename(TREE))
      File.binwrite(tree_path, tree_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work, sources: [tree_path, File.join(ROOT, FUZZ)], include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_machine_ctl_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMachineCtlFuzz.run(seed: seed)
end
