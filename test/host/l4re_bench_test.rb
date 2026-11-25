# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_session'
require_relative '../../tools/lib/erx/l4re_bench'

# L4Re's guest (docs/design-bench.md, "L4Re's guest"): the exported bootstrap.elf boots
# on one CPU through the shared QEMU plan, ends at the configuration script's last line,
# and its lines come back as mean cells through L4Re's importer. QEMU here is a stand-in
# that writes erXos-written lines in ipcbench's format as the serial log.
class L4ReBenchTest < Minitest::Test
  L4Re = Erx::L4ReBench
  Suite = Erx::BenchSuite

  LINES = ['L4 Bootstrapper', 'Syscall benchmark:',
           'sc:single | CPU  0 done 10000 syscalls in 1234567 cpu-cycles, 123 cpu-cycles/syscall',
           'ipc:1AS | CPU  0 done 20000 IPCs in 4200000 cpu-cycles, 210 cpu-cycles/IPC',
           "ipc:2AS | \e[31mgarbage", 'Benchmarks done.'].freeze

  # Records the run it is asked for and writes LINES as its serial log.
  class Qemu
    attr_reader :asked

    def initialize(directory) = @directory = directory

    def run(**plan)
      @asked = plan
      serial = File.join(@directory, 'serial.log')
      File.binwrite(serial, "#{LINES.join("\r\n")}\r\n")
      { 'serial_log' => serial, 'image_sha256' => Digest::SHA256.file(plan.fetch(:image)).hexdigest,
        'qemu_version' => '11.0.0', 'reused_from' => nil }
    end
  end

  def nullcall
    counterpart = { 'l4re' => 'ipcbench', 'linux' => 'getppid' }
    operation = ->(name) { Suite::Operation.new(name: name, profile: 'fast', result: 'ERX_OK', counterparts: counterpart) }
    cell = ->(name) { Suite::LandingCell.new(operation: name, load: 'idle', placement: 'same-cpu', parameters: {}) }
    names = %w[kernel root-same-space root-cross-space]
    Suite::Benchmark.new(name: 'nullcall',
                         operations: names.to_h { |name| [name, operation.call(name)] }
                                          .merge('erxos-only' => Suite::Operation.new(name: 'erxos-only', profile: 'fast',
                                                                                       result: 'ERX_OK')),
                         landing: { 'native' => [*names, 'erxos-only'].map { |name| cell.call(name) } })
  end

  ELF = "\x7fELF".b
  ELF_SHA256 = Digest::SHA256.hexdigest(ELF)

  def with_guest(built: true, record: { 'l4re_mk' => 'c' * 40, 'compiler' => 'gcc', 'bootstrap_sha256' => ELF_SHA256 })
    Dir.mktmpdir do |directory|
      build = L4Re::Build.new(directory: File.join(directory, 'l4re'))
      Dir.mkdir(build.directory)
      if built
        File.binwrite(build.bootstrap, ELF)
        File.binwrite(build.record_path, record.is_a?(String) ? record : JSON.generate(record))
      end
      qemu = Qemu.new(directory)
      yield L4Re::Guest.new(build: build, qemu: qemu, platform: :virt), qemu, build
    end
  end

  def test_the_guest_boots_bootstrap_on_one_cpu_with_no_command_line_or_host_link
    with_guest do |guest, qemu, build|
      assert_equal [1], guest.forms(4)
      assert_nil guest.refusal('full')
      guest.call(nullcall, cells: nullcall.landing.fetch('native').first(3), cpus: 1, accel: 'hvf')
      asked = qemu.asked
      assert_equal [build.bootstrap, 1, 'hvf', Erx::QemuPlan::NO_HOSTLINK, L4Re::MEMORY_MIB],
                   asked.values_at(:image, :cpus, :accel, :hostlink, :memory_mib)
      refute asked.key?(:command_line)
      refute asked.key?(:machine_end)
      assert_equal [L4Re::DONE], asked.fetch(:checkpoints)
    end
  end

  def test_the_boot_lines_come_back_as_mean_cells_with_the_build_record_as_subject
    with_guest do |guest, _qemu, _build|
      booted = guest.call(nullcall, cells: nullcall.landing.fetch('native').first(3), cpus: 1, accel: 'hvf')
      assert_nil booted.clock
      assert_equal %w[measured measured rejected], booted.cells.map(&:status)
      assert_equal({ 'count' => 10_000, 'total' => 4_200_000, 'mean' => 210 }, booted.cells[1].detail)
      assert_equal 1, booted.refused.size
      assert_equal({ 'l4re_mk' => 'c' * 40, 'compiler' => 'gcc', 'bootstrap_sha256' => ELF_SHA256 }, booted.subject)
      host = Erx::BenchSystem::Host.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 12, revision: 'a' * 40, dirty: false)
      record = Erx::BenchSystem.record(booted, system: 'l4re', cpus: 1, host: host, date: Time.now.utc, started_by: 'manual',
                                                load: nil)
      assert_equal 'l4re', record.environment.system
    end
  end

  # A record written for another ELF, or holding what a terminal or the record could
  # not show, describes no boot: the guest refuses it before QEMU starts.
  def test_a_stale_or_unprintable_build_record_is_refused_before_the_boot
    cells = nullcall.landing.fetch('native').first(3)
    [{ 'bootstrap_sha256' => 'b' * 64 }, { 'bootstrap_sha256' => ELF_SHA256, 'compiler' => "gcc \e[31m" },
     %({"bootstrap_sha256":"#{ELF_SHA256}","\xff":"x"}).b].each do |record|
      with_guest(record: record) do |guest, qemu, _build|
        assert_raises(Erx::Error) { guest.call(nullcall, cells: cells, cpus: 1, accel: 'hvf') }
        assert_nil qemu.asked
      end
    end
  end

def test_a_guest_not_built_is_refused_before_any_boot
    with_guest(built: false) do |guest, _qemu, build|
      assert_match(/#{Regexp.escape(build.bootstrap)}/, guest.refusal('landing'))
      error = assert_raises(Erx::Error) do
        Erx::BenchSession.plan(nullcall, systems: %w[l4re], profile: 'landing', guests: [guest])
      end
      assert_match(/bootstrap\.elf/, error.message)
    end
  end

  def test_a_session_boots_l4re_once_per_round_for_its_counterpart_cells_only
    with_guest do |guest, _qemu, _build|
      plan = Erx::BenchSession.plan(nullcall, systems: %w[l4re], profile: 'full', guests: [guest])
      assert_equal [[0, 1], [1, 1], [2, 1]], plan.steps.map { |step| [step.round, step.cpus] }
      assert_equal %w[kernel root-same-space root-cross-space], plan.steps.first.cells.map(&:operation)
      assert_raises(Erx::Error) { guest.call(nullcall, cells: plan.steps.first.cells, cpus: 4, accel: 'hvf') }
    end
  end
end
