# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/xdomain_bench'

# The xdomain bench image's pure parts (docs/design-bench.md, "5. `xdomain`: one message,
# one domain to another"): its manifest grants echo to peer, the client's domain; the boot
# asks for the declared cells on the counter with no pair; the run line passes the landing
# profile's sizes and the declared request size, so the guest's conditions are the declared
# ones; and the transcript loads every bench module into peer before the run line.
class XdomainBenchTest < Minitest::Test
  Bench = Erx::XdomainBench

  def asked = Bench.asked(%w[xdomain wake].map { |name| Erx::BenchSuite.benchmark(name) })

  def test_the_boot_asks_for_both_benchmarks_cells_on_the_counter_and_no_pair
    assert_equal [%w[xdomain local-rtt], %w[xdomain xdomain-pingpong], %w[wake erlang-timer]],
                 asked.cells.map { |wanted, declared| [wanted.benchmark.name, declared.operation] }
    assert_equal({ 'bytes' => 64, 'encoded' => 78 }, asked.cells.first.last.parameters)
    assert_equal 'counter', asked.clock
    assert_empty asked.pairs
  end

  def test_the_run_line_passes_each_guest_its_profiles_sizes_and_parameters
    fast, periodic = Erx::NativeBench::LANDING_PROFILES.values_at('fast', 'periodic')
    line = Bench.run_line(asked)
    assert_includes line, 'erpc:call(peer@erxos,erx_bench_hist,run,' \
                          "[[{erx_xdomain_bench,\#{warmup=>#{fast.warmup},samples=>#{fast.samples},bytes=>64,echo=>facet}}," \
                          "{erx_wake_bench,\#{samples=>#{periodic.samples},priorities=>[normal]}}]],"
    assert line.end_with?("io:format(\"#{Bench::DONE}~n\").\r")
  end

  # A boot cut short at a checkpoint may end inside a line, which is dropped; the rest
  # of the log's guest lines are kept, as they are for a boot that ran to its end.
  def test_a_timed_out_boot_drops_its_unclosed_last_line
    serial = "x\r\nCLOCK {}\r\nBENCH {\"a\":1}\r\nBENCH {\"a\""
    assert_equal ['CLOCK {}', 'BENCH {"a":1}'], Bench.lines(serial, timed_out: 'QEMU checkpoint timed out: cells')
    assert_equal ['CLOCK {}', 'BENCH {"a":1}', 'BENCH {"a"'], Bench.lines(serial, timed_out: nil)
  end

  def test_a_guest_argument_outside_the_declarations_is_refused
    wake = Erx::BenchSuite.benchmark('wake')
    timer = Erx::BenchSuite::LandingCell.new(operation: 'erlang-timer', load: 'idle', placement: 'runtime',
                                             parameters: { 'priority' => 'Normal' })
    odd = Erx::BenchMeasurement::Wanted.new(benchmark: wake, cells: [timer], profiles: Erx::NativeBench.profiles(wake))
    error = assert_raises(Erx::Error) { Bench.run_line(Erx::BenchMeasurement::Asked.new(benchmarks: [odd], clock: 'counter', pairs: [])) }
    assert_match(/priority is not one of/, error.message)
  end

  def test_the_manifest_grants_echo_to_peer
    source = Erx::Platform.development(File.expand_path('../..', __dir__)).site_manifest_source(File.expand_path('../..', __dir__))
    manifest = Bench.manifest(source)
    assert_includes manifest, Erx::SystemDomain::Regrant::PEER_FACET
    assert_includes manifest, "domain peer\n"
  end

  def test_the_transcript_loads_each_module_into_peer_before_the_run
    beams = Bench::MODULES.to_h { |name| [name, "\x01\x02".b * 200] }
    steps = Bench.exchanges(beams, asked)
    loads = steps.select { |step| step.answer == Erx::BenchGuest::BEAM_DIGEST }
    assert_equal Bench::MODULES.map { |name| "{module,#{name}}=erpc:call(peer@erxos,code,load_binary," },
                 loads.map { |step| step.line[/\A\{module,[a-z_]+\}=erpc:call\(peer@erxos,code,load_binary,/] }
    assert_equal Bench.run_line(asked), steps.last.line
    shell = { name: 'release-shell', pattern: /x/, seconds: 1 }.freeze
    points = Bench.checkpoints([{ name: 'boot', pattern: /y/, seconds: 1 }, shell], steps)
    assert_equal Erx::ProductionImage::Run::ERL_LINE, points[1].fetch(:type)
    assert_equal steps.first.line, points[2].fetch(:type)
    refute points.last.key?(:type)
    assert_match points.last.fetch(:pattern), "#{Bench::DONE}\r\n"
  end

  # The session's guest of the xdomain boot (Erx::BenchSystem): it boots the image at the
  # session's CPU count and judges the guest's lines against the benchmark's own cells, so a
  # boot cut short at a checkpoint keeps the cells it reported and the rest are timed_out.
  class FakeRun
    attr_reader :calls

    def initialize(measured)
      @measured = measured
      @calls = []
    end

    def memory_mib = 512

    def call(asked, accel:, cpus:)
      @calls << [asked.benchmarks.map { |wanted| wanted.benchmark.name }, accel, cpus]
      @measured
    end
  end

  def test_the_session_guest_boots_the_image_and_keeps_a_cut_boots_cells
    xdomain = Erx::BenchSuite.benchmark('xdomain')
    parameters = xdomain.landing.fetch('xdomain').first.parameters
    conditions = { 'load' => 'idle', 'placement' => 'runtime', 'parameters' => parameters, 'clock' => 'counter',
                   'batch' => 1 }
    samples = Erx::NativeBench::LANDING_PROFILES.fetch('fast').samples
    rtt = Erx::BenchLineFuzz.line('wake-same-cpu', benchmark: 'xdomain', operation: 'local-rtt', conditions: conditions,
                                                   samples: samples, histogram: [[1000, 1000, samples]], min: 1000, max: 1000,
                                                   largest: (0...16).map { |index| [index, 1000] })
    lines = [Erx::BenchLineFuzz.clock_line(pairs: []), rtt]
    # The boot wrote its serial log, as Run's does, and the guest keeps the log's bytes.
    Dir.mktmpdir('erx-xdomain-guest-') do |scratch|
      serial = File.join(scratch, 'serial.log')
      bytes = ['boot', *lines].map { |line| "#{line}\r\n" }.join.b
      File.binwrite(serial, bytes)
      run = FakeRun.new({ serial: serial, lines: lines, image_sha256: 'ab' * 32, workloads: {}, compiler: 'clang',
                          qemu_version: '10.1.0', reused_from: nil, timed_out: 'QEMU checkpoint timed out: bench-done' })
      guest = Bench::Guest.new(run: run)
      assert_equal %w[erxos xdomain], [guest.system, guest.boot]
      assert_equal [1, 4], guest.forms(4)
      assert_nil guest.refusal('landing')
      assert_match(/landing profiles only/, guest.refusal('full'))
      booted = guest.call(xdomain, cells: xdomain.landing.fetch('xdomain'), cpus: 1, accel: 'hvf')
      assert_equal [[['xdomain'], 'hvf', 1]], run.calls
      assert_empty booted.refused
      assert_equal [%w[local-rtt measured], %w[xdomain-pingpong timed_out]],
                   booted.cells.map { |cell| [cell.operation, cell.status] }
      assert_equal 'ab' * 32, booted.subject.fetch('image_sha256')
      assert_equal [{ serial: bytes }], booted.logs
    end
  end
end
