# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'

# The pipe NIF's hand-offs and program holder entries (docs/design-pipes.md, "Hand-offs" and
# Verification, Hand-offs and Program holders) through the session's pipe NIF,
# otp/erts/emulator/nifs/erxos/erx_pipe_nif.c, built for the host with ERX_PIPE_HARNESS, linked
# with test/fixtures/erx_pipe_harness.c and liberx's pipe core and loaded into stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies), under test/erlang/erx_pipe_hand_tests.erl:
# the owner's take once, a take for another owner, for another program or after the port's
# release (with or without a take before it) refused, hand_drop, an owner's exit and its holder_drop, the program's gone once after
# both holds in either order, hand_make's limits, and make_lock's numbering.
# erx_pipe_nif.erl is compiled with the harness's functions added. Seeded faults of the NIF must
# each fail the case named beside them.
class ErxPipeHandTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  NIF = File.join(NIFS, 'erx_pipe_nif.c')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_pipe_harness.c')
  CORE = %w[liberx/erx_pipe_check.c liberx/erx_pipe_core.c liberx/erx_pipe_run.c].map { |path| File.join(ROOT, path) }
  MODULE = 'erlang/apps/erx/src/erx_pipe_nif.erl'
  TESTS = %w[test/erlang/erx_pipe_hand_tests.erl].freeze
  HARNESS_FUNCTIONS = 'take/3, give/1, holder_release/1, closed/1, obj_cap/1'
  STUBS = <<~ERLANG
    take(_, _, _) -> erlang:nif_error(undef).
    give(_) -> erlang:nif_error(undef).
    holder_release(_) -> erlang:nif_error(undef).
    closed(_) -> erlang:nif_error(undef).
    obj_cap(_) -> erlang:nif_error(undef).
  ERLANG

  def test_hand_off_cases_pass_under_eunit
    output = run_cases(NIF)
    assert_match(/All \d+ tests passed/, output)
  end

  # A seeded fault of the NIF, the test function that must fail on it, and the edit.
  MUTANTS = {
    'a take ignores the owner' =>
      ['take_for_another_owner_answers_none_test', 'enif_is_identical((*link)->owner.pid, caller) &&', ''],
    'a take ignores the program' =>
      ['take_for_another_program_answers_none_test', '(*link)->program == program &&', ''],
    "a take after the port's release holds again" =>
      ['take_after_the_ports_release_is_refused_test', " &&\n\t    h->port_hold != PORT_RELEASED", ''],
    'a release before any take leaves the hold to take' =>
      ['release_before_any_take_is_final_test', '!= NULL && h->port_hold != PORT_RELEASED) {',
       '!= NULL && h->port_hold == PORT_HELD) {'],
    "the gone follows the owner's hold alone" =>
      ['gone_after_the_owner_then_the_port_test', 'if (h->owner_held || h->port_hold == PORT_HELD)', 'if (h->owner_held)'],
    'a hand-off carries any count of copies' =>
      ['hand_make_refuses_more_than_its_limits_test', " ||\n\t    n > ERX_PIPE_HAND_COPIES_MAX", ''],
    'hand_make takes a list of any length' =>
      ['hand_make_refuses_more_than_its_limits_test', " ||\n\t    n > ERX_PROG_FDS_MAX", '']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(NIF)
    Dir.mktmpdir('erx-pipe-hand-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the NIF"
        path = File.join(directory, 'erx_pipe_nif.c')
        File.write(path, source.sub(original, replacement))
        output = run_cases(path)
        assert_match(/erx_pipe_hand_tests: #{expected}[^\n]*\*failed\*/, output, "seeded fault not caught: #{name}")
      end
    end
  end

  private

  def run_cases(nif)
    Dir.mktmpdir('erx-pipe-hand-') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: TESTS, replaced: { MODULE => module_with_harness })
      build_nif(work, nif)
      output, = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120',
                                ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                'halt(case eunit:test(erx_pipe_hand_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                chdir: work, stdin_data: '')
      output
    end
  end

  def module_with_harness
    source = File.read(File.join(ROOT, MODULE))
    exports = 'hand_make/2, hand_drop/1, program_holder/1, holder_drop/1, holder_owner/1]).'
    assert_equal 2, source.scan(exports).size, 'the -nifs and -export lists end alike'
    "#{source.gsub(exports, "hand_make/2, hand_drop/1, program_holder/1, holder_drop/1, holder_owner/1,\n" \
                            "#{HARNESS_FUNCTIONS}]).")}\n#{STUBS}"
  end

  # erx_pipe_nif.so in work, from nif, the harness and the pipe core linked together, against the
  # headers of the emulator ERX_ERL runs. ERX_PIPE_HARNESS adds the harness's functions to the NIF's
  # table (erx_pipe_harness.h).
  def build_nif(work, nif)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17',
                                     '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror', *Erx::HostOs::NIF_LINK_FLAGS,
                                     '-DERX_PIPE_NIF_LOADABLE', '-DERX_PIPE_HARNESS', '-I', File.dirname(HARNESS),
                                     '-I', NIFS, '-I', File.join(ROOT, 'otp/erts/emulator/sys/erxos'),
                                     '-I', File.join(root, 'usr/include'), '-I', ROOT,
                                     '-I', File.join(ROOT, 'build/gen/include'), '-I', File.join(ROOT, 'include'),
                                     '-o', File.join(work, 'erx_pipe_nif.so'), nif, HARNESS, *CORE,
                                     stdin_data: '')
    assert status.success?, output
  end
end
