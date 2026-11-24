# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/xdomain_bench'

# The xdomain bench image's pure parts (docs/design-bench.md, "5. `xdomain`"): its
# manifest grants echo to peer, the client's domain; the boot asks for the declared cells
# on the counter with no pair; the run line passes the landing profile's sizes and the
# declared request size, so the guest's conditions are the declared ones; and the
# transcript loads every bench module into peer before the run line.
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
                          "[[{erx_xdomain_bench,\#{warmup=>#{fast.warmup},samples=>#{fast.samples},bytes=>64}}," \
                          "{erx_wake_bench,\#{samples=>#{periodic.samples},priorities=>[normal]}}]],"
    assert line.end_with?("io:format(\"#{Bench::DONE}~n\").\r")
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
end
