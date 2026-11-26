# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/genode_bench'

# Genode's guest (docs/design-bench.md, "Genode's guest"): the importer of its serial log
# the build record it boots, and how its boot ends.
class GenodeBenchTest < Minitest::Test
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  # The program's lines are the ones behind its label, with the label dropped; Genode's
  # own lines, another component's, and an unlabelled line that looks like the
  # program's are not.
  def test_only_the_components_labelled_lines_are_the_programs
    serial = "kernel initialized\r\n[init -> erx_peer_bench] CLOCK counter 62500000\n" \
             "[init -> timer] BENCH forged\nBENCH unlabelled\n[init -> erx_peer_bench] erx: bench: done\n" \
             "[init -> erx_peer_bench] BENCH posix.getpid 1\n"
    assert_equal ['CLOCK counter 62500000', 'BENCH posix.getpid 1'], Erx::GenodeBench.lines(serial)
    assert Erx::GenodeBench.checkpoints.last.fetch(:pattern).match?('[init -> erx_peer_bench] erx: bench: done')
  end

  # Genode's LOG prints a message longer than its line as several lines, each behind the
  # label, so the program writes a long record as its first piece and MORE lines that fit
  # (test/fixtures/genode_bench/posix.serial.log: a boot's CLOCK, getpid and
  # clock-gettime records re-split as the program splits them). The importer keeps the
  # MORE lines and the reader joins them, so each record is judged whole.
  def test_records_written_in_pieces_are_judged_whole
    serial = File.binread(File.expand_path('../fixtures/genode_bench/posix.serial.log', __dir__))
    lines = Erx::GenodeBench.lines(serial)
    assert lines.all? { |line| line.bytesize <= Erx::GenodeBuild::MACHINE.piece_bytes }
    answer = Erx::BenchMeasurement.boot(lines, Erx::PeerBench.asked('posix', cpus: 4, clock: 'counter', pinned: false))
    assert_equal [], answer.fetch(:refused)
    status = answer.fetch(:cells).to_h { |cell| [cell.operation, cell.status] }
    assert_equal %w[failed measured], status.values_at('getpid', 'clock-gettime')
  end

  # What base-hw on QEMU's virt allows at the pinned release is one declaration: it boots
  # under TCG alone, entered at the hypervisor's level, always on four CPUs, and its C
  # library refuses to pin, so the guest, the build and the program's arguments all follow
  # it and no caller passes any of it.
  def test_the_guest_boots_as_the_machine_declaration_allows
    machine = Erx::GenodeBuild::MACHINE
    assert_equal [%w[tcg], 4, true, false, 230],
                 [machine.accelerators, machine.cpus, machine.virtualization, machine.pinned, machine.piece_bytes]
    flags = Erx::GenodeBuild.staged_inputs(Dir.pwd, arguments: Erx::GenodeBuild.arguments, cpus: 4)
                            .fetch('repo/src/app/erx_peer_bench/flags.mk')
    assert_includes flags.split, '-DERX_PEER_PIECE_BYTES=230u'
    # The program and QEMU's checkpoint both take TCG's deadline, its one accelerator's.
    assert_includes flags.split, "-DERX_PEER_RUN_DEADLINE_S=#{Erx::PeerBench.run_deadline('tcg')}u"
    assert_equal Erx::PeerBench.run_deadline('tcg') + Erx::NativeBench::DEADLINE_MARGIN_SECONDS,
                 Erx::GenodeBench.checkpoints.last.fetch(:seconds)
    guest = Erx::GenodeBench::Guest.new(root: Dir.pwd, runner: nil, platform: nil)
    assert_equal [%w[tcg], [4], [4]], [guest.accelerators, guest.forms(1), guest.forms(4)]
    assert_equal %w[posix 4 unpinned], Erx::GenodeBuild.arguments
  end

  # The record must name the image beside it; a rebuilt image refuses the stale record.
  def test_the_record_names_its_image
    Dir.mktmpdir do |root|
      build = Erx::GenodeBench.build(root: root, cpus: 2)
      assert_equal File.join(root, 'build/genode/2cpu'), build.directory
      FileUtils.mkdir_p(build.directory)
      File.write(build.image, 'ELF')
      File.write(build.record_path, JSON.generate('image_sha256' => Digest::SHA256.hexdigest('ELF'), 'cpus' => 2))
      assert_equal 2, build.record.fetch('cpus')
      File.write(build.image, 'ELF2')
      assert_raises(Erx::Error) { build.record }
    end
  end

  # base-hw does not power off when its program exits, so its machine declaration says
  # so and the harness ends the boot at its last checkpoint, the program's done line: a
  # guest still running there passes and is stopped, not left to its deadline.
  def test_the_boot_ends_at_the_programs_done_line
    Dir.mktmpdir do |root|
      build_from_tree(root)
      label = Erx::GenodeBench::LABEL
      serial = "#{label}erx: bench: timing\n#{label}erx: bench: done\n[init] child exited with exit value 0\n"
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      qemu = Erx::Qemu.new(root: root, runner: runner, program: lingering_guest(root, serial, seconds: 120))
      guest = Erx::GenodeBench::Guest.new(root: root, runner: runner, platform: PLATFORM, qemu: qemu)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      guest.call(Data.define(:name).new(name: 'posix'), cells: nil, cpus: 4, accel: 'tcg')
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 60
      report = JSON.parse(File.read(Dir.glob(File.join(root, 'build/qemu/*/report.json')).fetch(0)))
      assert_equal 'passed', report.fetch('state')
    end
    refute Erx::GenodeBuild::MACHINE.powers_off
  end

  # The record names the digest of what the build staged from the tree; a change to any
  # staged file refuses the image built before it.
  def test_an_image_staged_from_other_files_is_refused
    Dir.mktmpdir do |root|
      build_from_tree(root)
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      guest = Erx::GenodeBench::Guest.new(root: root, runner: runner, platform: PLATFORM, qemu: nil)
      File.write(File.join(root, 'bench/peer/erx_peer_bench.c'), 'int main(void) { return 1; }')
      error = assert_raises(Erx::Error) do
        guest.call(Data.define(:name).new(name: 'posix'), cells: nil, cpus: 4, accel: 'tcg')
      end
      assert_match(/other inputs than the tree stages/, error.message)
    end
  end

  private

  # A tree of the program's files under root, and an image with the record a build of
  # them writes.
  def build_from_tree(root)
    [Erx::GenodeBuild::SCRIPT, Erx::GenodeBuild::TARGET, 'bench/peer/erx_peer_bench.c', 'test/guest/bench/clock.h',
     'liberx/backend/core/mem.h'].each do |path|
      FileUtils.mkdir_p(File.join(root, File.dirname(path)))
      File.write(File.join(root, path), path)
    end
    build = Erx::GenodeBench.build(root: root, cpus: 4)
    FileUtils.mkdir_p(build.directory)
    File.write(build.image, 'ELF')
    File.write(build.record_path, JSON.generate('image_sha256' => Digest::SHA256.hexdigest('ELF'), 'cpus' => 4,
                                                'arguments' => Erx::GenodeBuild.arguments,
                                                'staged_sha256' => Erx::GenodeBuild.staged_sha256(
                                                  Erx::GenodeBuild.staged_inputs(root, arguments: Erx::GenodeBuild.arguments, cpus: 4)
                                                )))
  end

  # A QEMU that prints serial on its serial file and then stays up for seconds, as
  # base-hw does after its program exits.
  def lingering_guest(root, serial, seconds:)
    path = File.join(root, 'fake-qemu')
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV.include?('--version')
        puts 'QEMU emulator version 11.1.3 (fixture)'
        exit 0
      end
      File.binwrite(ARGV.fetch(ARGV.index('-serial') + 1).delete_prefix('file:'), #{serial.dump})
      sleep #{seconds}
    RUBY
    File.chmod(0o700, path)
    path
  end
end
