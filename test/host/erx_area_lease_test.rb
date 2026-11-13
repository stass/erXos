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
# test/erlang/erx_area_lease_tests.erl: lend/5's refusals, noproc for an exited holder
# with the table left as it was and the area's destructor run, every way a lease ends,
# through the harness's stand-ins for the program driver, and zero/3; and under
# test/erlang/erx_pixels_tests.erl, the allocator erx_pixels over that NIF: lend's
# refusals and its wait, zeroing before reuse, an orphaned range kept out until its
# return, and the area let go once no range is live. erx_area.erl is compiled with the
# harness's functions added. Seeded faults of the NIF, its C core, erx_pixels and
# erx_pixels_core must each fail the case named beside them.
class ErxAreaLeaseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  NIF = File.join(NIFS, 'erx_area_nif.c')
  HARNESS = File.join(ROOT, 'test/display/erx_area_harness.c')
  AREA = 'erlang/apps/erx/src/erx_area.erl'
  CORE = File.join(NIFS, 'erx_area_lease_core.c')
  PIXELS = 'erlang/apps/erx_win/src/erx_pixels.erl'
  PIXELS_CORE = 'erlang/apps/erx_win/src/erx_pixels_core.erl'
  TESTS = %w[test/erlang/erx_area_lease_tests.erl test/erlang/erx_pixels_tests.erl].freeze
  SUITES = '[erx_area_lease_tests, erx_pixels_tests]'
  HARNESS_FUNCTIONS = 'take/3, give/1, map_lease/2, leases/0, peek/3, poke/3'
  STUBS = <<~ERLANG
    take(_, _, _) -> erlang:nif_error(undef).
    give(_) -> erlang:nif_error(undef).
    map_lease(_, _) -> erlang:nif_error(undef).
    leases() -> erlang:nif_error(undef).
    peek(_, _, _) -> erlang:nif_error(undef).
    poke(_, _, _) -> erlang:nif_error(undef).
  ERLANG

  def test_lease_cases_pass_under_eunit
    output = run_cases
    assert_match(/All \d+ tests passed/, output)
  end

  # A seeded fault: the file it edits (NIF, CORE or an Erlang module of TESTS' applications),
  # the anchor found once there and its replacement, and the case that must fail on it.
  # crashes: the fault may store outside the area and end the emulator inside its case,
  # which then counts as failing when it is the last case the run started.
  Mutant = Data.define(:file, :anchor, :replacement, :catching_case, :crashes) do
    def initialize(file:, anchor:, replacement:, catching_case:, crashes: false) = super
  end

  MUTANTS = {
    'lend reads its integers as signed' =>
      Mutant.new(file: NIF, catching_case: 'lend_refusals_test', anchor: "!enif_get_uint64(env, argv[1], &offset) ||\n\t    !enif_get_uint64(env, argv[2], &pages) || !enif_get_local_pid",
                 replacement: "!enif_get_int64(env, argv[1], (ErlNifSInt64 *)&offset) ||\n\t    !enif_get_uint64(env, argv[2], &pages) || !enif_get_local_pid"),
    "lend ignores the monitor's failure" =>
      Mutant.new(file: NIF, catching_case: 'noproc_test',
                 anchor: 'if (enif_monitor_process(env, lease, &holder, &lease->monitor) != 0) {',
                 replacement: 'if (enif_monitor_process(env, lease, &holder, &lease->monitor) < 0) {'),
    'a take ignores the holder' =>
      Mutant.new(file: NIF, catching_case: 'taken_lease_waits_for_its_driver_test',
                 anchor: 'enif_is_identical(lease->holder.pid, owner) && ', replacement: ''),
    'zero/3 without its bound check' =>
      Mutant.new(file: CORE, catching_case: 'zero_refusals_test', crashes: true,
                 anchor: 'if (__builtin_mul_overflow(pages, page, &bytes) || __builtin_add_overflow(offset, bytes, &end))',
                 replacement: 'if ((bytes = pages * page, end = offset + bytes, false))'),
    'zero/3 zeroes a page too many' =>
      Mutant.new(file: NIF, catching_case: 'zero_clears_exactly_its_range_test', crashes: true,
                 anchor: '(size_t)(pages * ERX_PAGE_SIZE));', replacement: '(size_t)((pages + 1) * ERX_PAGE_SIZE));'),
    'a lend without its owner check' =>
      Mutant.new(file: PIXELS_CORE, catching_case: 'lend_refusals_test',
                 anchor: '{ok, #range{owner = Owner, live = true} = Range}', replacement: '{ok, #range{live = true} = Range}'),
    'an allocator that refuses a range with a lease outstanding' =>
      Mutant.new(file: PIXELS_CORE, catching_case: 'lend_waits_for_the_last_return_test',
                 anchor: '{store(Core, Start, Range#range{waiting = From}), Refused};',
                 replacement: '{Core, [{reply, From, {error, einval}}]};'),
    'an allocator that skips the zeroing' =>
      Mutant.new(file: PIXELS, catching_case: 'reuse_is_zeroed_test',
                 anchor: 'ok = erx_area:zero(Area, Offset, Pages),', replacement: '_ = Area,'),
    'an allocator that takes a return by its number alone' =>
      Mutant.new(file: PIXELS, catching_case: 'forged_return_changes_nothing_test',
                 anchor: '#{Lease := {Peer, Tag}} ->', replacement: '#{Lease := {Peer, _}} ->'),
    "an allocator that keeps the area's term" =>
      Mutant.new(file: PIXELS, catching_case: 'area_is_let_go_once_no_range_is_live_test',
                 anchor: '{Idle =/= [], State#state{areas = maps:without(Idle, Areas)}}.',
                 replacement: '{Idle =/= [], State}.')
  }.freeze

  def test_seeded_faults_are_caught
    Dir.mktmpdir('erx-area-lease-mutant-') do |directory|
      MUTANTS.each do |name, mutant|
        output = run_cases(**seeded(mutant, directory, name))
        started = output.scan(/erx_\w+_tests: (\w+)\.\.\./).flatten.last
        caught = output.match?(/erx_\w+_tests: #{mutant.catching_case}[^\n]*\*failed\*/) ||
                 (mutant.crashes && started == mutant.catching_case && !output.include?('tests passed'))
        assert caught, "seeded fault not caught: #{name}\n#{output}"
      end
    end
  end

  private

  # The run's arguments for mutant: its file's text with the anchor replaced, written to
  # directory for a C file and handed to ErlangBuild for an Erlang module.
  def seeded(mutant, directory, name)
    path = [NIF, CORE].include?(mutant.file) ? mutant.file : File.join(ROOT, mutant.file)
    source = File.read(path)
    assert_equal 1, source.scan(mutant.anchor).size, "mutant #{name} must edit exactly one place of #{mutant.file}"
    text = source.sub(mutant.anchor, mutant.replacement)
    return { replaced: { mutant.file => text } } unless [NIF, CORE].include?(mutant.file)

    copy = File.join(directory, File.basename(path))
    File.write(copy, text)
    mutant.file == NIF ? { nif: copy } : { core: copy }
  end

  def run_cases(nif: NIF, core: CORE, replaced: {})
    Dir.mktmpdir('erx-area-lease-') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_win], tests: TESTS,
                                replaced: { AREA => area_with_harness }.merge(replaced))
      build_nif(work, nif, core)
      output, = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120',
                                ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                "halt(case eunit:test(#{SUITES}, [verbose]) of ok -> 0; _ -> 1 end).",
                                chdir: work, stdin_data: '')
      output
    end
  end

  def area_with_harness
    source = File.read(File.join(ROOT, AREA))
    exports = '-export([open/1, map/4, lend/5, unlend/1, zero/3]).'
    assert_equal 1, source.scan(exports).size
    "#{source.sub(exports, "#{exports}\n-export([#{HARNESS_FUNCTIONS}]).\n-nifs([#{HARNESS_FUNCTIONS}]).")}\n#{STUBS}"
  end

  # erx_area.so in work, from nif and the harness linked together, against the headers of the emulator
  # ERX_ERL runs. ERX_AREA_HARNESS adds the harness's functions to the NIF's table (erx_area_harness.h).
  def build_nif(work, nif, core)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17',
                                     '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror', *Erx::HostOs::NIF_LINK_FLAGS,
                                     '-DERX_AREA_NIF_LOADABLE', '-DERX_AREA_HARNESS', '-I', File.dirname(HARNESS),
                                     '-I', NIFS, '-I', File.join(root, 'usr/include'),
                                     '-I', ROOT, '-I', File.join(ROOT, 'build/gen/include'), '-I', File.join(ROOT, 'include'),
                                     '-o', File.join(work, 'erx_area.so'), nif, HARNESS, core,
                                     stdin_data: '')
    assert status.success?, output
  end
end
