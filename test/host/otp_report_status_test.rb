# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/otp_report_status_tests.erl, the cases of edit 75 of
# docs/design-runtime.md (docs/design-log.md, "Reports carry no term"), on stock's
# emulator (ERX_ERL and ERX_ERLC) with the tree's proc_lib, gen, gen_server, gen_statem, sys,
# edlin, edlin_key and group compiled into the work directory and loaded over stock's at boot. Then each
# seeded fault, applied to a copy of the tree's module, must fail the case named for it.
class OtpReportStatusTest < Minitest::Test
  STDLIB = 'otp/lib/stdlib'
  KERNEL = 'otp/lib/kernel'
  OTP_MODULES = (%w[proc_lib gen gen_server gen_statem sys edlin edlin_key].map { |name| "#{STDLIB}/src/#{name}.erl" } +
                 ["#{KERNEL}/src/group.erl"]).freeze
  TESTS = %w[otp_report_status_tests otp_report_status_hiding otp_report_status_crashing
             otp_report_status_crashing_server otp_report_status_changing]
          .map { |name| "test/erlang/#{name}.erl" }.freeze
  DEADLINE_SECONDS = '120'
  HIDES = 'server_with_format_status_hides_the_secret_test'

  Seed = Data.define(:fault, :source, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "each frame's arguments kept", source: "#{STDLIB}/src/gen.erl",
             anchor: '        true -> report_frames(Stacktrace);',
             replacement: '        true -> Stacktrace;',
             catching_case: HIDES),
    Seed.new(fault: "each frame's location kept", source: "#{STDLIB}/src/gen.erl",
             anchor: '        Arity -> [{M, F, Arity, []} | report_frames(Frames)]',
             replacement: '        Arity -> [{M, F, Arity, _Location} | report_frames(Frames)]',
             catching_case: 'reason_and_location_carry_the_secret_test'),
    Seed.new(fault: "the crash report's mailbox kept", source: "#{STDLIB}/src/proc_lib.erl",
             anchor: '            hidden -> {{messages, []}, {dictionary, []}}',
             replacement: '            hidden -> {get_messages(self()), {dictionary, []}}',
             catching_case: HIDES),
    Seed.new(fault: 'a change of callback module not recorded', source: "#{STDLIB}/src/gen_statem.erl",
             anchor: '            ok = gen:status_module_changed(Module),',
             replacement: '            _ = Module,',
             catching_case: 'statem_that_changes_to_a_hiding_module_hides_the_secret_test'),
    Seed.new(fault: 'a crashed format_status shows the raw data', source: "#{STDLIB}/src/gen_statem.erl",
             anchor: %q(shown_status(#{'EXIT' := Failure} = Status) ->),
             replacement: %q(shown_status(#{'EXIT_' := Failure} = Status) ->),
             catching_case: 'statem_whose_format_status_crashes_hides_the_secret_test'),
    Seed.new(fault: 'a crashed format_status shows the raw sys log', source: "#{STDLIB}/src/gen_server.erl",
             anchor: %q(shown_log(#{'EXIT' := _}) -> [];),
             replacement: %q(shown_log(#{'EXIT_' := _}) -> [];),
             catching_case: 'crashed_format_status_shows_no_log_test'),
    Seed.new(fault: 'a cut frame given to length/1', source: "#{STDLIB}/src/gen_server.erl",
             anchor: 'frame_arity(A) when is_integer(A) -> A;',
             replacement: '',
             catching_case: 'undef_of_a_hiding_server_formats_test'),
    Seed.new(fault: "the group's typed input kept", source: "#{KERNEL}/src/group.erl",
             anchor: '    maps:map(fun(data, #state{} = Data) -> hidden_input(Data);',
             replacement: '    maps:map(fun(data, #state{} = Data) -> Data;',
             catching_case: 'group_status_hides_the_input_test'),
    Seed.new(fault: "a pushed request's typed input kept", source: "#{KERNEL}/src/group.erl",
             anchor: '{State, hidden_input_state(PushedInput)}',
             replacement: '{State, PushedInput}',
             catching_case: 'group_status_hides_the_input_test'),
    Seed.new(fault: "the group's postponed input kept", source: "#{KERNEL}/src/group.erl",
             anchor: '                   [hidden_event(Event) || Event <- Events];',
             replacement: '                   Events;',
             catching_case: 'group_status_hides_the_input_test'),
    Seed.new(fault: "a hiding process's status dictionary kept", source: "#{STDLIB}/src/sys.erl",
             anchor: '                true -> [];',
             replacement: '                true -> get();',
             catching_case: 'group_status_hides_the_kill_buffer_test')
  ].freeze

  def test_report_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.read(File.join(ErlangBuild::ROOT, seed.source))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.source => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  # replaced maps a module of OTP_MODULES to the text compiled in its place. The default
  # handler is removed so that no report it prints parts a case from its verdict.
  def run_cases(replaced)
    Dir.mktmpdir('otp-report-status') do |work|
      compile_otp(work, replaced)
      ErlangBuild.compile(work, applications: [], tests: TESTS)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-nostick',
                      '-pa', work, '-eval',
                      'ok = logger:remove_handler(default), ' \
                      'halt(case eunit:test(otp_report_status_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end

  def compile_otp(work, replaced)
    sources = OTP_MODULES.map do |source|
      next File.join(ErlangBuild::ROOT, source) unless replaced.key?(source)

      File.join(work, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
    end
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', File.join(ErlangBuild::ROOT, STDLIB, 'include'),
                                     '-I', File.join(ErlangBuild::ROOT, STDLIB, 'src'), '-I', File.join(ErlangBuild::ROOT, KERNEL, 'include'),
                                     '-o', work, *sources,
                                     stdin_data: '')
    assert status.success?, output
  end
end
