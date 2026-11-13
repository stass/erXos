# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/host_os'

# erx_area's leases (docs/design-display.md, "The pixel area", The lease and
# Verification) through erx_area's own NIF, otp/erts/emulator/nifs/erxos/erx_area_nif.c,
# built for the host with ERX_AREA_HARNESS, linked with test/display/erx_area_harness.c
# and loaded into stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), under
# test/erlang/erx_area_lease_tests.erl: lend/4's refusals, noproc for an exited holder
# with the table left as it was and the area's destructor run, and every way a lease
# ends, through the harness's stand-ins for the program driver. erx_area.erl is compiled
# with the harness's functions added. Seeded faults of the NIF must each fail the case
# named beside them.
class ErxAreaLeaseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  NIF = File.join(NIFS, 'erx_area_nif.c')
  HARNESS = File.join(ROOT, 'test/display/erx_area_harness.c')
  AREA = 'erlang/apps/erx/src/erx_area.erl'
  TESTS = %w[test/erlang/erx_area_lease_tests.erl].freeze
  HARNESS_FUNCTIONS = 'take/3, give/1, map_lease/2, leases/0'
  STUBS = <<~ERLANG
    take(_, _, _) -> erlang:nif_error(undef).
    give(_) -> erlang:nif_error(undef).
    map_lease(_, _) -> erlang:nif_error(undef).
    leases() -> erlang:nif_error(undef).
  ERLANG

  def test_lease_cases_pass_under_eunit
    output = run_cases(NIF)
    assert_match(/All \d+ tests passed/, output)
  end

  # A seeded fault of the NIF, the test function that must fail on it, and the edit.
  MUTANTS = {
    'lend reads its integers as signed' =>
      ['lend_refusals_test', '!enif_get_uint64(env, argv[1], &offset)',
       '!enif_get_int64(env, argv[1], (ErlNifSInt64 *)&offset)'],
    "lend ignores the monitor's failure" =>
      ['noproc_test', 'if (enif_monitor_process(env, lease, &holder, &lease->monitor) != 0) {',
       'if (enif_monitor_process(env, lease, &holder, &lease->monitor) < 0) {'],
    'a take ignores the holder' =>
      ['taken_lease_waits_for_its_driver_test', 'enif_is_identical(lease->holder.pid, owner) && ', '']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(NIF)
    Dir.mktmpdir('erx-area-lease-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the NIF"
        path = File.join(directory, 'erx_area_nif.c')
        File.write(path, source.sub(original, replacement))
        output = run_cases(path)
        assert_match(/erx_area_lease_tests: #{expected}[^\n]*\*failed\*/, output, "seeded fault not caught: #{name}")
      end
    end
  end

  private

  def run_cases(nif)
    Dir.mktmpdir('erx-area-lease-') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: TESTS, replaced: { AREA => area_with_harness })
      build_nif(work, nif)
      output, = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120',
                                ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                'halt(case eunit:test(erx_area_lease_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                chdir: work, stdin_data: '')
      output
    end
  end

  def area_with_harness
    source = File.read(File.join(ROOT, AREA))
    exports = '-export([open/1, map/4, lend/4, unlend/1]).'
    assert_equal 1, source.scan(exports).size
    "#{source.sub(exports, "#{exports}\n-export([#{HARNESS_FUNCTIONS}]).\n-nifs([#{HARNESS_FUNCTIONS}]).")}\n#{STUBS}"
  end

  # erx_area.so in work, from nif and the harness linked together, against the headers of the emulator
  # ERX_ERL runs. ERX_AREA_HARNESS adds the harness's functions to the NIF's table (erx_area_harness.h).
  def build_nif(work, nif)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17',
                                     '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror', *Erx::HostOs::NIF_LINK_FLAGS,
                                     '-DERX_AREA_NIF_LOADABLE', '-DERX_AREA_HARNESS', '-I', File.dirname(HARNESS),
                                     '-I', NIFS, '-I', File.join(root, 'usr/include'),
                                     '-I', ROOT, '-I', File.join(ROOT, 'build/gen/include'), '-I', File.join(ROOT, 'include'),
                                     '-o', File.join(work, 'erx_area.so'), nif, HARNESS, File.join(NIFS, 'erx_area_lease_core.c'),
                                     stdin_data: '')
    assert status.success?, output
  end
end
