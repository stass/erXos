# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'pty'
require 'tmpdir'
require_relative '../../tools/lib/erx/runtime'
require_relative '../../tools/lib/erx/runtime_seam'

# ERTS built with ERLANG_OSTYPE=erxos, driven through a terminal as a person would:
# `1>`, an expression, its answer, then halt, over the stock terminal driver.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older
# than the tree, it fails: nothing is skipped.
class RuntimeHostedSmokeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  # A boot to `1>` takes seconds; the budget is the whole dialogue on a loaded host.
  BUDGET_SECONDS = 60
  ESCAPE_SEQUENCE = /\e\[[0-9;?]*[A-Za-z]/n

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_terminal_gets_a_prompt_and_evaluates
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home) do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        writer.write("1+1.\n")
        read_until(reader, transcript, /^2\n.*^2> /m, deadline)
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        status = wait_for(pid, deadline, transcript)
        @reaped = true
        assert status.success?, "the runtime ended with #{status.inspect}\n#{plain(transcript)}"
      end
    end
  end

  def test_the_runtime_links_liberx_and_its_imports_are_on_the_list
    # The makefile names this object after ERLANG_OSTYPE, and only sys/erxos holds its source.
    assert_path_exists File.join(OUTPUT.objects, 'erl_erxos_sys_ddll.o')
    assert(Erx::RuntimeSeam.defined_names(OUTPUT.beam).any? { |name| name.start_with?('erx_') },
           'hosted liberx is in the executable')
    report = Erx::RuntimeSeam.check_objects(objects: Erx::RuntimeSeam.objects(OUTPUT), liberx: OUTPUT.liberx,
                                            executable: OUTPUT.beam, imports_path: File.join(OUTPUT.root, Erx::RuntimeSeam::IMPORTS_FILE))
    assert_empty report.violations.map { |violation| "#{violation.object}: #{violation.name}" }
  end

  private

  def spawn_shell(home)
    bin = File.dirname(OUTPUT.beam)
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge(
      'BINDIR' => bin, 'ROOTDIR' => OUTPUT.root, 'EMU' => 'beam', 'PROGNAME' => 'erl', 'HOME' => home, 'TERM' => 'xterm'
    )
    arguments = ['--', '-root', OUTPUT.root, '-bindir', bin, '-progname', 'erl', '--', '-home', home, '--',
                 '-boot', File.join(OUTPUT.root, 'bootstrap/bin/start')]
    PTY.spawn(environment, OUTPUT.beam, *arguments, chdir: home) do |reader, writer, pid|
      yield reader, writer, pid
    ensure
      end_if_running(pid)
    end
  end

  # The child leads a session of its own, with erl_child_setup in its group.
  def end_if_running(pid)
    return if @reaped

    Process.kill('KILL', -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def read_until(reader, transcript, pattern, deadline)
    until pattern.match?(plain(transcript))
      remaining = deadline - monotonic
      flunk("no #{pattern.inspect} within #{BUDGET_SECONDS} s\n#{plain(transcript)}") unless remaining.positive?
      chunk = read_chunk(reader, remaining)
      flunk("the terminal closed before #{pattern.inspect}\n#{plain(transcript)}") if chunk.nil?
      transcript << chunk
    end
  end

  def read_to_end(reader, transcript, deadline)
    while (remaining = deadline - monotonic).positive?
      chunk = read_chunk(reader, remaining)
      return if chunk.nil?

      transcript << chunk
    end
    flunk("the runtime did not close its terminal within #{BUDGET_SECONDS} s\n#{plain(transcript)}")
  end

  # nil at end of input: a closed pty reads as EIO on macOS.
  def read_chunk(reader, seconds)
    return '' unless reader.wait_readable(seconds)

    chunk = reader.read_nonblock(4096, exception: false)
    chunk == :wait_readable ? '' : chunk&.force_encoding(Encoding::BINARY)
  rescue EOFError, Errno::EIO
    nil
  end

  def wait_for(pid, deadline, transcript)
    while monotonic < deadline
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited.last if waited

      IO.select(nil, nil, nil, 0.05)
    end
    flunk("the runtime did not exit within #{BUDGET_SECONDS} s\n#{plain(transcript)}")
  end

  def plain(transcript) = transcript.b.gsub(ESCAPE_SEQUENCE, '').delete("\r")
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
