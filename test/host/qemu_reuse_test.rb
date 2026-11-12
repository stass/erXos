# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu'
require_relative '../../tools/lib/erx/qemu_gate'
require_relative '../../tools/lib/erx/qemu_reuse'

# A boot that passed is reused only on byte-identical inputs, only after its
# suite passed, and never from a record the store cannot vouch for. The guest
# is a stand-in QEMU that logs each start, so a reused boot is one that did
# not start.
class QemuReuseTest < Minitest::Test
  Reuse = Erx::QemuReuse
  CHECKPOINTS = [{ name: 'done', pattern: /^done\r?\n/n, seconds: 5 }].freeze
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  def setup
    @directory = Dir.mktmpdir('erx-qemu-reuse-')
    @starts = File.join(@directory, 'starts')
    @version = File.join(@directory, 'version')
    File.write(@version, "QEMU emulator version 11.1.3 (fixture)\n")
    @image = File.join(@directory, 'image.elf')
    File.write(@image, 'fixture image')
    @store = Reuse::Store.new(directory: File.join(@directory, 'store'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def guest(output: "booting\ndone\n")
    path = File.join(@directory, 'fake-qemu')
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      # #{File.read(@version).strip}
      if ARGV.include?('--version')
        print File.read(#{@version.dump})
        exit 0
      end
      File.open(#{@starts.dump}, 'a') { |starts| starts.puts('start') }
      File.binwrite(ARGV.fetch(ARGV.index('-serial') + 1).delete_prefix('file:'), #{output.dump})
    RUBY
    File.chmod(0o700, path)
    path
  end

  def starts = File.file?(@starts) ? File.readlines(@starts).size : 0

  def session(fresh: false, harness: 'a' * 64) = Reuse::Session.new(store: @store, harness: harness, fresh: fresh)

  # One suite's worth of boots under session; returns the reports and Boots.
  def boot(session, passed: true, output: "booting\ndone\n", checkpoints: CHECKPOINTS, **options)
    qemu = Erx::Qemu.new(root: @directory, program: guest(output: output))
    report, boots = session.suite('stand-in') do
      qemu.run(platform: PLATFORM, accel: 'tcg', image: @image, checkpoints: checkpoints, **options)
    end
    [report, boots.close(passed: passed)]
  end

  def record_path = Dir.glob(File.join(@store.directory, '*.json')).fetch(0)

  def test_a_passing_boot_is_reused_on_the_same_inputs_and_runs_on_none_other
    _, first = boot(session)
    assert_equal [1, []], [first.fresh, first.reused]
    report, second = boot(session)
    assert_equal 1, starts, 'a reused boot does not start QEMU'
    assert_equal [0, 1], [second.fresh, second.reused.size]
    assert_equal second.reused.first, report.fetch('reused_from')
    assert_equal "booting\ndone\n", File.binread(report.fetch('serial_log'))
    assert_equal ['done'], report.fetch('checkpoints').map { |point| point.fetch('name') }
  end

  # Each case changes one input from the recorded boot's and boots once.
  def test_one_changed_input_runs_the_boot_again
    cases = {
      'image byte' => lambda do
        File.write(@image, 'fixture imagf')
        boot(session)
      end,
      'QEMU' => lambda do
        File.write(@version, "QEMU emulator version 11.1.4 (fixture)\n")
        boot(session)
      end,
      'CPU count' => -> { boot(session, cpus: 2) },
      'harness' => -> { boot(session(harness: 'b' * 64)) },
      'command line' => -> { boot(session, command_line: 'erx.debug=1') },
      'transcript' => -> { boot(session, checkpoints: [CHECKPOINTS.first.merge(seconds: 6)]) }
    }
    cases.each do |input, change|
      FileUtils.rm_rf(@store.directory)
      File.write(@image, 'fixture image')
      File.write(@version, "QEMU emulator version 11.1.3 (fixture)\n")
      boot(session)
      before = starts
      change.call
      assert_equal before + 1, starts, "a changed #{input} must run the boot"
    end
  end

  def test_a_suite_that_did_not_pass_records_nothing
    boot(session, passed: false)
    boot(session)
    assert_equal 2, starts
  end

  def test_each_reuse_of_one_boot_counts
    boot(session)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    _, boots = session.suite('stand-in') { 2.times { qemu.run(platform: PLATFORM, accel: 'tcg', image: @image, checkpoints: CHECKPOINTS) } }
    assert_equal 2, boots.close(passed: true).reused.size
  end

  def test_a_suite_that_failed_on_a_reused_boot_boots_it_again_next_time
    boot(session)
    _, failed = boot(session, passed: false)
    assert_equal [1, 1], [starts, failed.reused.size]
    boot(session)
    assert_equal 2, starts
  end

  def test_a_stored_log_that_a_verifier_now_rejects_runs_fresh
    rejecting = [CHECKPOINTS.first.merge(verify: ->(_) { raise Erx::Error, 'rejected' if @reject })]
    boot(session, checkpoints: rejecting)
    @reject = true
    assert_raises(Erx::Error) { boot(session, checkpoints: rejecting) }
    assert_equal 2, starts
  end

  def test_a_boot_that_did_not_complete_its_transcript_is_not_recorded
    assert_raises(Erx::Error) { boot(session, output: "booting\n") }
    boot(session)
    assert_equal 2, starts
  end

  def test_a_fresh_session_runs_every_boot_and_still_records
    boot(session)
    _, fresh = boot(session(fresh: true))
    assert_equal [2, 1], [starts, fresh.fresh]
    boot(session)
    assert_equal 2, starts
  end

  def test_a_boot_with_a_disk_always_runs
    disk = Erx::QemuPlan::Disk.new(path: File.join(@directory, 'disk.img'))
    boot(session, disks: [disk])
    boot(session, disks: [disk])
    assert_equal 2, starts
  end

  def test_a_malformed_or_changed_record_is_a_miss_with_a_diagnostic
    boot(session)
    damages = {
      'truncated' => ->(record, _) { File.write(record, '{"format": ') },
      'infinite time' => ->(record, _) { File.write(record, File.read(record).sub(/"elapsed_seconds": [0-9.e-]+\n/, "\"elapsed_seconds\": 1e400\n")) },
      'changed log' => ->(_, log) { File.write(log, "booting\nforged\ndone\n") },
      'unreadable log' => ->(_, log) { File.chmod(0o000, log) }
    }
    damages.each do |name, damage|
      next if name == 'unreadable log' && Process.euid.zero? # root reads it anyway
      FileUtils.rm_rf(@store.directory)
      boot(session)
      record = record_path
      damage.call(record, record.sub(/\.json\z/, '.log'))
      assert_match(/1e400/, File.read(record)) if name == 'infinite time'
      before = starts
      _, boots = boot(session)
      assert_equal before + 1, starts
      assert_match(/record .* the boot runs fresh/, boots.diagnostics.join("\n"))
    end
  end

  def test_the_harness_digest_covers_every_harness_file
    root = File.join(@directory, 'tree')
    FileUtils.mkdir_p(File.join(root, 'tools/lib/erx/qemu_suites'))
    File.write(File.join(root, 'tools/erx'), 'entry')
    File.write(File.join(root, 'tools/lib/erx/qemu.rb'), 'harness')
    suite = File.join(root, 'tools/lib/erx/qemu_suites/one.rb')
    File.write(suite, 'suite')
    before = Reuse.harness_digest(root)
    File.write(suite, 'suitf')
    refute_equal before, Reuse.harness_digest(root)
  end

  def test_the_gate_lists_each_reused_log
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    suite = Erx::QemuGate::Suite.new(name: 'stand-in', cells: ['tcg-1cpu'], run: lambda do |_|
      qemu.run(platform: PLATFORM, accel: 'tcg', image: @image, checkpoints: CHECKPOINTS)
      Erx::QemuGate.result({ 'tcg-1cpu' => 'passed' })
    end)
    context = Erx::QemuGate::Context.new(root: @directory, jobs: 1)
    2.times { @results = Erx::QemuGate.run(suites: [suite], context: context, reuse: session) }
    lines = Erx::QemuGate.table(@results)
    assert_match(/tcg-1cpu passed \(1 of 1 boots reused\)\z/, lines[0])
    assert_match(%r{\Astand-in: reused from #{Regexp.escape(@store.directory)}/\h{64}\.log\z}, lines[1])
    assert_match(/; 1 boots reused from earlier passes; /, lines.last)
  end
end
