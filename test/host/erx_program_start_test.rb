# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# erx_program:start/1's startup message builder (otp/erts/preloaded/src/erx_program.erl),
# run on stock's emulator (ERX_ERL and ERX_ERLC) with the generated grammar
# erx_prog_grammar. start/1 builds the message before it opens the port, so every refusal
# here comes back before any driver is named; a spec it accepts goes on to open_port,
# which stock refuses with badarg, since it has no erx_program driver. The E2BIG bounds
# are exact (docs/design-abi.md, "Program protocol"): one argument of prog_args_max bytes
# is within its own maximum but past the args total by its NUL, and one byte less is not;
# a message whose frame, with every capability value at its longest encoding, is
# prog_frame_max bytes reaches the driver, and one a byte longer does not. The module is
# compiled with export_all, so AtBound can size that frame with erx_program:message/3.
class ErxProgramStartTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  GRAMMAR = File.join(ROOT, 'build/gen/otp/erts/preloaded/src/erx_prog_grammar.erl')
  MODULE = File.join(ROOT, 'otp/erts/preloaded/src/erx_program.erl')
  LIMITS = File.foreach(File.join(ROOT, 'abi/protocols/prog.txt')).filter_map do |line|
    line.match(/\Alimit (\w+) u32 (\d+)$/)&.captures
  end.to_h.transform_values { |value| Integer(value, 10) }.freeze
  ARGS_MAX = LIMITS.fetch('prog_args_max')
  FRAME_MAX = LIMITS.fetch('prog_frame_max')

  # Each case: a spec, an Erlang expression over Base (the spec every case starts from) and
  # AtBound, and what start/1 must print for it.
  CASES = {
    'one argument past the total by its NUL' => ["Base#{'#'}{argv => [binary:copy(<<\"a\">>, #{ARGS_MAX})]}", '{error,e2big}'],
    'one argument at the total with its NUL' => ["Base#{'#'}{argv => [binary:copy(<<\"a\">>, #{ARGS_MAX - 1})]}", 'driver'],
    'an environment past the total' => ["Base#{'#'}{env => [<<\"A=\", (binary:copy(<<\"b\">>, #{ARGS_MAX}))/binary>>]}",
                                        '{error,e2big}'],
    'a relative working directory' => ["Base#{'#'}{cwd => <<\"home\">>}", '{error,einval}'],
    'an unknown signal' => ["Base#{'#'}{sigmask => [nosuchsignal]}", '{error,einval}'],
    'a missing argv' => ['maps:remove(argv, Base)', '{error,einval}'],
    'a descriptor' => ["Base#{'#'}{fds => [{0, null}]}", 'badarg'],
    'slots past the data area' => ["Base#{'#'}{slots => 17}", '{error,einval}'],
    'a message at the frame bound' => ['AtBound(0)', 'driver'],
    'a message a byte past the frame bound' => ['AtBound(1)', '{error,e2big}'],
    'the base spec' => ['Base', 'driver']
  }.freeze

  BASE = '#{image => <<"bin/args">>, pid => 5, ppid => 1, pgid => 5, argv => [<<"args">>], env => [], ' \
         'cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022}'

  # AtBound(Over): Base with argv grown until its frame, with the data area's value at its
  # longest encoding (the largest u64), is Over bytes past prog_frame_max. Empty arguments,
  # five bytes of frame for one of the args total each, take it past the total's reach; the
  # last argument pads it, adding its length and five bytes. The 4 slots stand for any slot
  # count, which all encode alike, so the frame is the one start/1 checks.
  AT_BOUND = <<~ERLANG
    AtBound = fun(Over) ->
                  Argv = [<<"args">> | lists:duplicate(30000, <<>>)],
                  Filled = Base\#{argv => Argv},
                  {ok, Frame} = erx_prog_grammar:build_start(erx_program:message(Filled, 16#ffffffffffffffff, 4)),
                  Pad = #{FRAME_MAX} + Over - byte_size(term_to_binary(Frame)) - 5,
                  Filled\#{argv => Argv ++ [binary:copy(<<"a">>, Pad)]}
              end,
  ERLANG

  def test_the_builder_refuses_before_the_port_opens
    Dir.mktmpdir('erx-program-start-') do |dir|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '+export_all', '+nowarn_export_all', '-o', dir,
                                       GRAMMAR, MODULE, stdin_data: '')
      assert status.success?, output
      got = CASES.to_h { |name, (expression, _)| [name, answer(dir, expression)] }
      want = CASES.transform_values(&:last)
      assert_equal want, got
    end
  end

  private

  # What start/1 answers for the spec expression: its result, 'badarg' for a badarg of
  # start/1 itself, or 'driver' for open_port's badarg, past the builder.
  def answer(dir, expression)
    erlang = <<~ERLANG
      Base = #{BASE},
      #{AT_BOUND}
      R = try erx_program:start(#{expression}) of
            Result -> io_lib:format("~0p", [Result])
          catch
            error:badarg:Stack ->
              case Stack of
                [{erlang, open_port, _, _} | _] -> "driver";
                [{erx_program, start, _, _} | _] -> "badarg";
                _ -> io_lib:format("~0p", [{badarg, hd(Stack)}])
              end;
            Class:Reason -> io_lib:format("~0p", [{Class, Reason}])
          end,
      io:format("~s~n", [R]),
      halt().
    ERLANG
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', dir,
                                     '-eval', erlang, stdin_data: '')
    assert status.success?, output
    output.lines.last.to_s.chomp
  end
end
