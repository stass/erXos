# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/rc_oracle'

# The command shell's evaluator against its oracle (docs/design-shell.md,
# "Verification and testing"): every script of test/shell/rc/corpus runs
# under plan9port's rc and under erx_shell_eval with erx_shell_fake_runner,
# and their standard output, standard error and final $status must agree.
# The corpus uses rc's language alone and the commands echo, true and false,
# which the fake runner and the host's /bin both provide. A script that ends
# on a fault of the language ends rc with no status, which the evaluator
# reports as a fault. Each difference found is a bug, or is classified in
# DIFFERENCES and pinned there to the evaluator's own output.
class ErxShellCorpusTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORPUS = File.join(ROOT, 'test/shell/rc/corpus')
  SOURCES = %w[erlang/apps/erx_shell/src/erx_shell_lex.erl erlang/apps/erx_shell/src/erx_shell_parse.erl
               erlang/apps/erx_shell/src/erx_shell_eval.erl
               test/erlang/erx_shell_fake_runner.erl].map { |path| File.join(ROOT, path) }.freeze

  Run = Data.define(:stdout, :stderr, :status)

  # Scripts whose runs differ, each with why and what the evaluator gives
  # instead, pinned so a change on the evaluator's side shows; rc is not run
  # for them.
  DIFFERENCES = {
    # rc prints a function's body as its parser deparses it; the syntax
    # tree keeps no source text and the evaluator has no printer of trees
    # (TODO.md), so whatis says it cannot show the body.
    'whatis-function' => Run.new(stdout: "st not supported\n", stderr: "f: a function; its body is not shown\n",
                                 status: 'ok '),
    # rc's parser refuses an `if not' that does not directly follow an `if',
    # across units too; erx_shell_parse does not check it (TODO.md), so
    # the evaluator runs the second `if not' on the flag the `if' left.
    'if-not-follows' => Run.new(stdout: "first\nsecond\nafter\n", stderr: '', status: 'ok '),
    # rc keeps its internal mark on a pattern character written unquoted in
    # a subject of ~, so `a*' there equals no quoted text; the evaluator
    # takes a subject as text, so it equals 'a*'. Kept: rc's result follows
    # from its internal representation, not from its language.
    'match-subject' => Run.new(stdout: "star-subject \nstar-both \n", stderr: '', status: 'ok '),
    # A fault inside a substitution: rc's forked child exits and its parent
    # sees exit status 1; the evaluator's copy keeps rc's own fault status.
    'substitution-fault' => Run.new(stdout: "bq error\n", stderr: "rc: null list in concatenation\n",
                                    status: 'ok ')
  }.freeze

  def self.scripts = Dir[File.join(CORPUS, '*.rc')].sort

  # The modules are compiled once for every script.
  def self.compiled
    @compiled ||= Dir.mktmpdir('erx-shell-corpus-').tap do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      raise "compiling the evaluator failed: #{output}" unless status.success?

      Minitest.after_run { FileUtils.remove_entry(work) }
    end
  end

  def setup
    @oracle = Erx::RcOracle.locate(root: ROOT)
    @work = self.class.compiled
  end

  scripts.each do |script|
    name = File.basename(script, '.rc')
    define_method("test_#{name.tr('-', '_')}_agrees_with_rc") do
      ours = evaluator_run(script)
      expected = DIFFERENCES.fetch(name) { oracle_run(script) }
      assert_equal(expected.to_h, ours.to_h, "#{name}.rc: the evaluator and rc disagree")
    end
  end

  private

  def oracle_run(script)
    directory = Dir.mktmpdir('oracle-', @work)
    path = File.join(directory, 'script.rc')
    FileUtils.cp(script, path)
    result = @oracle.run(path)
    status = case result.state
             # erx_shell_eval:status/1 is $status's first word, as rc reads it.
             when :completed then "ok #{result.status.first}"
             when :exited then 'fault'
             else flunk("rc gave #{result.describe} for #{script}")
             end
    Run.new(stdout: result.stdout, stderr: result.stderr, status: status)
  end

  def evaluator_run(script)
    directory = Dir.mktmpdir('run-', @work)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', @work,
                                     '-run', 'erx_shell_fake_runner', 'main', script, directory, stdin_data: '')
    assert status.success?, "#{script}: #{output}"
    outcome, final = File.read(File.join(directory, 'status')).lines(chomp: true)
    Run.new(stdout: File.read(File.join(directory, 'stdout')), stderr: File.read(File.join(directory, 'stderr')),
            status: outcome == 'ok' ? "ok #{final}" : 'fault')
  end
end
