# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/xdomain_bench'

# The Erlang guests' bench library and the xdomain guest on stock OTP (docs/design-bench.md,
# "The histogram", "5. `xdomain`", "Verification"): the histogram's buckets hold their
# samples and are at most 1/64 of their lower bound wide; erx_xdomain_bench's lines, with
# a stand-in erx whose echo facet is a process of the same node, are what the xdomain
# boot asks for and BenchMeasurement.boot accepts them; a facet whose reply is not its
# request fails its cell. Seeded faults must each fail a check.
class ErxBenchHistTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULES = %w[erx_bench_hist erx_xdomain_bench].freeze
  # A stand-in for erXos's erx: cap(echo) answers a registered process of this node that
  # replies to {echo, T} with Reply(T).
  STAND_IN = <<~ERLANG
    -module(erx).
    -export([cap/1, serve/1]).
    cap(echo) -> whereis(erx_echo_stand_in).
    serve(Reply) ->
        register(erx_echo_stand_in, spawn(fun() -> loop(Reply) end)), ok.
    loop(Reply) ->
        receive {'$gen_call', From, {echo, T}} -> gen:reply(From, {echo, Reply(T)}), loop(Reply) end.
  ERLANG
  HIST_CHECK = 'Bad=[V||K<-lists:seq(0,19),J<-lists:seq(0,300),V<-[(1 bsl K)+J*((1 bsl K) div 300+1)],' \
               '{L,X}<-[erx_bench_hist:bounds(erx_bench_hist:bucket(V))],' \
               'not (L=<V andalso V=<X andalso (X-L+1)*64=<max(64,L))],' \
               'io:format("~s~n",[case Bad of [] -> "hist ok"; _ -> "hist bad" end])'
  RUN = 'erx:serve(%s),[io:format("~s~n",[L])||L<-erx_xdomain_bench:run(#{warmup=>1000,samples=>10000,bytes=>64})]'

  def setup
    skip 'the emu oracle is not built here (make oracle-bootstrap)' unless
      File.directory?(File.join(ROOT, 'build/oracle/emu/install'))
    @directory = Dir.mktmpdir('erx-bench-hist-')
  end

  def teardown = @directory && FileUtils.remove_entry(@directory)

  def test_each_sample_lies_in_a_narrow_bucket_and_an_off_by_one_index_is_caught
    assert_equal ['hist ok'], evaluate(HIST_CHECK, compiled)
    shifted = compiled(edit: ['((Value bsr Shift) band (?SUB - 1))', '(((Value bsr Shift) + 1) band (?SUB - 1))'])
    assert_equal ['hist bad'], evaluate(HIST_CHECK, shifted)
  end

  def test_the_xdomain_lines_are_what_the_boot_asks_for
    answer = judged(format(RUN, 'fun(T) -> T end'))
    assert_empty answer.fetch(:refused)
    assert_equal({ 'local-rtt' => 'measured', 'xdomain-pingpong' => 'measured' },
                 answer.fetch(:cells).to_h { |cell| [cell.operation, cell.status] })
    assert_equal 1_000_000_000, answer.fetch(:clock).fetch('frequency_hz')
  end

  def test_a_reply_that_is_not_its_request_fails_its_cell
    cells = judged(format(RUN, 'fun(_) -> other end')).fetch(:cells).to_h { |cell| [cell.operation, cell] }
    assert_equal 'measured', cells.fetch('local-rtt').status
    assert_equal %w[failed a\ reply\ was\ not\ its\ request], cells.fetch('xdomain-pingpong').then { |cell| [cell.status, cell.reason] }
  end

  private

  # The guest's lines under the stand-in erx, judged as the xdomain boot judges them.
  def judged(expression)
    lines = evaluate(expression, compiled(stand_in: true)).grep(Erx::NativeBench::GUEST_LINE)
    Erx::BenchMeasurement.boot(lines, Erx::XdomainBench.asked(Erx::BenchSuite.benchmark('xdomain')))
  end

  # The bench modules compiled into a directory of their own, with edit, [old, new],
  # applied to erx_bench_hist first, and the stand-in erx where asked.
  def compiled(edit: nil, stand_in: false)
    directory = Dir.mktmpdir('beams-', @directory)
    sources = MODULES.map do |name|
      text = File.read(File.join(ROOT, 'bench', "#{name}.erl"))
      if edit && name == 'erx_bench_hist'
        assert_equal 1, text.scan(edit.first).size, 'the seeded fault no longer applies'
        text = text.sub(edit.first, edit.last)
      end
      File.join(directory, "#{name}.erl").tap { |path| File.write(path, text) }
    end
    sources << File.join(directory, 'erx.erl').tap { |path| File.write(path, STAND_IN) } if stand_in
    runtime do |erl, erlc|
      _, status = Open3.capture2e(erlc, '+warnings_as_errors', '-o', directory, *sources, stdin_data: '')
      assert status.success?, 'the bench modules do not compile'
      @erl = erl
    end
    directory
  end

  def evaluate(expression, directory)
    output, status = Open3.capture2e(@erl, '-noshell', '-pa', directory, '-eval', "#{expression}, halt().", stdin_data: '')
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  def runtime
    Erx::Oracle.new(root: ROOT).with_runtime('emu') { |runtime| yield runtime.fetch('erl'), runtime.fetch('erlc') }
  end
end
