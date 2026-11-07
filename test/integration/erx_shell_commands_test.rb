# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/rc_oracle'

# The command shell's runner against its oracle (docs/design-shell.md,
# "Verification and testing"): every script of test/shell/rc/commands runs
# under plan9port's rc, with the host's commands, and under erx_shell with
# its own runner and Erlang commands (erx_shell_script:main/1), each from an empty working directory,
# and their standard output, standard error and final $status must agree.
# The scripts use echo, cat, true, false, mkdir, cp, mv, rm and ls, with
# redirections to files, here documents, pipelines, substitutions and
# globbing. Each difference found is a bug, or is classified in DIFFERENCES
# and pinned there to erx_shell's own output.
class ErxShellCommandsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORPUS = File.join(ROOT, 'test/shell/rc/commands')
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [File.join(ROOT, 'erlang/apps/erx/src/erx_text_tables.erl'), File.join(APPLICATION, 'erx_cmd.erl'),
             *Dir[File.join(APPLICATION, '*.erl')].sort].uniq.freeze

  Run = Data.define(:stdout, :stderr, :status)

  # Scripts whose runs differ, each with why and what erx_shell gives
  # instead, pinned so a change on erx_shell's side shows; rc is not run
  # for them.
  DIFFERENCES = {
    # A command's error is its status, as file:format_error/1 writes it,
    # where the host's cat exits 1 and words its diagnostic as strerror does.
    'cat-missing' => Run.new(stdout: "status no such file or directory\n",
                             stderr: "cat: nofile: no such file or directory\n", status: 'ok ')
  }.freeze

  def self.scripts = Dir[File.join(CORPUS, '*.rc')].sort

  # The application is compiled once for every script, with its
  # application file beside it, from which the command namespace is read.
  def self.compiled
    @compiled ||= Dir.mktmpdir('erx-shell-commands-').tap do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-pa', work, '-o', work, *SOURCES,
                                       stdin_data: '')
      raise "compiling the shell failed: #{output}" unless status.success?

      FileUtils.cp(File.join(APPLICATION, 'erx_shell.app.src'), File.join(work, 'erx_shell.app'))
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
      ours = shell_run(script)
      expected = DIFFERENCES.fetch(name) { oracle_run(script) }
      assert_equal(expected.to_h, ours.to_h, "#{name}.rc: erx_shell and rc disagree")
    end
  end

  private

  def oracle_run(script)
    directory = Dir.mktmpdir('oracle-', @work)
    path = File.join(directory, 'script.rc')
    FileUtils.cp(script, path)
    result = @oracle.run(path)
    status = case result.state
             when :completed then "ok #{result.status.first}"
             when :exited then 'fault'
             else flunk("rc gave #{result.describe} for #{script}")
             end
    Run.new(stdout: result.stdout, stderr: result.stderr, status: status)
  end

  def shell_run(script)
    output = Dir.mktmpdir('run-', @work)
    cwd = Dir.mktmpdir('cwd-', @work)
    log, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', @work,
                                  '-run', 'erx_shell_script', 'main', script, output, cwd, stdin_data: '')
    assert status.success?, "#{script}: #{log}"
    outcome, final = File.read(File.join(output, 'status')).lines(chomp: true)
    Run.new(stdout: File.read(File.join(output, 'stdout')), stderr: File.read(File.join(output, 'stderr')),
            status: outcome == 'ok' ? "ok #{final}" : 'fault')
  end
end
