# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/data_volume'
require_relative '../../tools/lib/erx/f2fs_oracle_guest'
require_relative '../../tools/lib/erx/line_escape'
require_relative '../../tools/lib/erx/runner'

# The F2FS oracle guest (docs/design-f2fs.md, "The Linux oracle guest"): how the host reads
# and judges what the guest prints, and how it lays out a batch; then, with
# ERX_F2FS_ORACLE=1 and the guest's pins fetched, two boots. The first checks erXos's
# fresh formats and Linux's own at the same sizes with fsck.f2fs and Linux's mount; the
# second has Linux list every corpus image and compares each listing with erXos's. Each
# boot's files stay in build/f2fs-oracle/ until the next run.
class F2fsOracleGuestTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  GUEST = Erx::F2fsOracleGuest
  NAMES = %w[vault].freeze
  ORACLE_OFF = 'the F2FS oracle guest boots Linux under QEMU for minutes; set ERX_F2FS_ORACLE=1 to run it'
  # What the guest printed for an image it never reached.
  NOTHING = Erx::F2fsOracleGuest::Result.new(outputs: {}, statuses: {})
  # A record (erx_f2fs_listing:record_reader/1) of the root alone: an empty file system.
  ROOT_ONLY = /\A\.\0d\0[0-7]{1,6}\0[0-9]{1,20}\0[0-9]{1,20}\0[0-9]{1,20}\0\0\z/n
  TESTS = %w[test/erlang/erx_f2fs_codec_tests.erl test/erlang/erx_f2fs_corpus.erl test/erlang/erx_f2fs_mount_tests.erl
             test/erlang/erx_f2fs_core_tests.erl test/erlang/erx_f2fs_listing.erl
             test/erlang/erx_f2fs_volume_tests.erl].freeze

  # A step's lines as the guest prints them: its chunks, then its size line.
  def lines(name, step, bytes)
    chunks = [bytes].pack('m0').scan(/.{1,8}/).map { |chunk| "erx-f2fs: out #{name} #{step} #{chunk}" }
    [*chunks, "erx-f2fs: size #{name} #{step} #{bytes.bytesize} #{Digest::SHA256.hexdigest(bytes)}"]
  end

  def read(lines) = GUEST.read(lines.join("\r\n"), names: NAMES)

  def test_read_gathers_each_steps_output_and_status
    serial = ['[    1.0] boot noise', 'erx-f2fs: kernel 7.0.0-34-generic', *lines('vault', 'fsck', "Info: ok\n[FSCK] done\n"),
              'erx-f2fs: exit vault fsck 0', *lines('vault', 'mount', ''), 'erx-f2fs: exit vault mount 32', "erx-f2fs: done\r"]
    batch = read(serial)
    assert_equal '7.0.0-34-generic', batch.kernel
    assert batch.done
    result = batch.results.fetch('vault')
    assert_equal({ 'fsck' => "Info: ok\n[FSCK] done\n", 'mount' => '' }, result.outputs)
    assert_equal({ 'fsck' => 0, 'mount' => 32 }, result.statuses)
    assert_equal :pass, GUEST.fsck_verdict(result, control: result)
  end

  def test_read_refuses_a_line_of_no_known_form
    ['erx-f2fs: exit vault fsck', 'erx-f2fs: out Vault fsck AAAA', 'erx-f2fs: out vault shell AAAA',
     "erx-f2fs: kernel \e[2J", 'erx-f2fs: exit vault fsck 0 extra', 'erx-f2fs: size vault fsck 0 abc'].each do |line|
      assert_raises(Erx::Error, line) { read([line]) }
    end
  end

  # The console can lose or break a line; every such loss is refused, never read as a
  # shorter output. The first case is the seeded fault: one chunk dropped.
  def test_read_refuses_a_step_whose_lines_were_lost
    output = lines('vault', 'fsck', 'x' * 40)
    cases = { 'a dropped chunk' => output.values_at(0, 2...output.size),
              'a dropped size line' => output[0...-1],
              'a chunk after its size line' => [*output, output.first],
              'a step printed twice' => [*output, *output],
              'a status printed twice' => [*output, *['erx-f2fs: exit vault fsck 0'] * 2],
              'a size of other bytes' => [*output[0...-1], output.last.sub(/ 40 /, ' 41 ')],
              'a broken base64 chunk' => [output.first.sub(/.\z/, '='), *output.drop(1)],
              'a status with no output' => ['erx-f2fs: exit vault fsck 0'],
              'a doubled space' => [output.first.sub(' fsck ', '  fsck ')] }
    cases.each do |why, serial|
      assert_raises(Erx::Error, why) { read(serial) }
    end
  end

  # The prefix anywhere but at a line's start, a line after the batch ended and an image
  # the batch never asked for are refused, each escaped in the refusal.
  def test_read_refuses_stray_lines
    { 'the prefix inside a line' => ["[  2.0] oops\e[2Jerx-f2fs: exit vault fsck 0"],
      'a line after done' => ['erx-f2fs: done', "erx-f2fs: exit vault fsck 0\e[2J"],
      'an image never asked for' => ["erx-f2fs: exit other\e[2J fsck 0"],
      'a second kernel line' => ['erx-f2fs: kernel 1', 'erx-f2fs: kernel 2'] }.each do |why, serial|
      error = assert_raises(Erx::Error, why) { read(serial) }
      refute_match(/\e/, error.message, why)
    end
  end

  def test_serial_log_is_read_within_its_bound
    Dir.mktmpdir('erx-f2fs-oracle-test') do |directory|
      log = File.join(directory, 'serial.log')
      File.binwrite(log, 'x' * 10)
      assert_equal 'x' * 10, GUEST.serial_log(log)
      File.open(log, 'wb') { |file| file.truncate(GUEST::SERIAL_BYTES + 1) }
      assert_raises(Erx::Error) { GUEST.serial_log(log) }
    end
  end

  # fsck.f2fs repairs some faults in check mode and exits 0, so its lines decide too; a
  # failing line passes only if the same boot's control printed it verbatim.
  def test_fsck_fails_on_a_repair_line_or_a_status
    result = ->(output, code) { GUEST::Result.new(outputs: { 'fsck' => output }, statuses: { 'fsck' => code }.compact) }
    clean = result.call("Info: clean\n", 0)
    assert_equal :pass, GUEST.fsck_verdict(clean, control: clean)
    ["[FIX] (fsck_chk_inode_blk: 1)\n", "[ASSERT] (sanity_check_nid)\n", "[FSCK] fixing SIT types\n", "[FSCK] fixing NAT\n",
     "Info: Reconnect 1 files\n"].each do |output|
      refute_equal :pass, GUEST.fsck_verdict(result.call(output, 0), control: clean), output
    end
    refute_match(/\e/, GUEST.fsck_verdict(result.call("[FIX] \e[2J\n", 0), control: clean))
    assert_equal 'fsck.f2fs exited 255', GUEST.fsck_verdict(result.call('', 255), control: clean)
    assert_equal 'fsck.f2fs did not report its exit status', GUEST.fsck_verdict(result.call('', nil), control: clean)
  end

  # A failing line the control printed verbatim says nothing about the image; the seeded
  # fault is the first case: a line only the image prints, which must fail.
  def test_fsck_benign_lines_are_the_controls
    result = ->(output) { GUEST::Result.new(outputs: { 'fsck' => output }, statuses: { 'fsck' => 0 }) }
    control = result.call("Info: ok\n[FSCK] fixing SIT types\n")
    { "[FSCK] fixing SIT types\n" => GUEST::Result.new(outputs: {}, statuses: {}),
      "[FSCK] fixing SIT types and more\n" => control, "[FSCK] fixing SIT\n" => control,
      "[FSCK] fixing SIT types\n[FIX] (nat)\n" => control }.each do |output, against|
      refute_equal :pass, GUEST.fsck_verdict(result.call(output), control: against), output
    end
    assert_equal :pass, GUEST.fsck_verdict(result.call("Info: other\n[FSCK] fixing SIT types\n"), control: control)
    assert_equal :pass, GUEST.fsck_verdict(control, control: control)
  end

  # The script fills the first MiB; each file follows at a MiB-aligned offset, as the
  # script's calls say, and an all-zero MiB stays a hole of the right length; probes come
  # after the checks.
  def test_batch_layout
    Dir.mktmpdir('erx-f2fs-oracle-test') do |directory|
      tools = File.join(directory, 'tools.deb')
      File.binwrite(tools, 'T' * 10)
      image = File.join(directory, 'one.img')
      File.binwrite(image, ("\0" * (1 << 20)) + ('I' * 512))
      batch = File.join(directory, 'batch.img')
      GUEST.write_batch(batch, body: "body\n", tools: tools, images: [GUEST::Image.new(name: 'one', path: image)],
                               probes: [GUEST::Probe.new(name: 'two', mib: 1024, arguments: %w[-s 2])])
      text = File.binread(batch, 200)
      assert_equal "body\nhashed=#{GUEST::HASHED_BYTES}\ntools 1048576 10\ncheck one 2097152 1049088\nprobe two 1024 -s 2\nfinish\n", text[0, text.index("\0")]
      assert_equal 'T' * 10, File.binread(batch, 10, 1 << 20)
      assert_equal 'I' * 512, File.binread(batch, 512, (2 << 20) + (1 << 20))
      assert_equal (3 << 20) + 512, File.size(batch)
    end
  end

  # A hostile image that ends the guest must not take erXos's verdicts with it; a probe's
  # arguments reach the guest's shell, so each is a plain option.
  def test_a_batch_holds_one_origin
    Dir.mktmpdir('erx-f2fs-oracle-test') do |directory|
      path = File.join(directory, 'one.img')
      File.binwrite(path, 'I' * 512)
      images = [GUEST::Image.new(name: 'one', path: path), GUEST::Image.new(name: 'two', path: path, origin: :foreign)]
      error = assert_raises(Erx::Error) { GUEST.run(root: ROOT, runner: nil, images: images, directory: directory) }
      assert_match(/one origin/, error.message)
      assert_raises(Erx::Error) { GUEST::Probe.new(name: 'p', mib: 64, arguments: ['-s;reboot']) }
    end
  end

  # erXos's format, one segment a section (docs/design-f2fs.md, "Formatting a volume"),
  # at the vault's size, the packed data partition's and 1 GiB, each beside its control,
  # Linux's own mkfs.f2fs at the same size: fsck.f2fs finds nothing to repair that the
  # control does not show too, and Linux mounts each read-only and lists only the empty
  # root.
  def test_erxos_and_linux_formats_pass_fsck_and_mount_empty
    runner, directory = guest('formats')
    images = { 'vault' => 64 << 11, 'data' => Erx::MediumImage::PACKED_DATA_SECTORS,
               'large' => 1 << 21 }.map do |name, sectors|
      GUEST::Image.new(name: name, path: format(directory, name, sectors: sectors, runner: runner))
    end
    controls = images.to_h do |image|
      [image.name, GUEST::Probe.new(name: "linux-#{image.name}", mib: File.size(image.path) >> 20)]
    end
    batch, = GUEST.run(root: ROOT, runner: runner, images: images, probes: controls.values, directory: directory)
    keep(directory, batch)
    assert batch.done, 'the guest did not reach its end'
    results = [*images, *controls.values].to_h { |image| [image.name, batch.results.fetch(image.name, NOTHING)] }
    controls.each_value { |probe| assert_equal 0, results.fetch(probe.name).statuses['mkfs'], escaped(results.fetch(probe.name), 'mkfs') }
    results.each do |name, result|
      assert_equal 0, result.statuses['mount'], "#{name}:\n#{escaped(result, 'mount')}#{escaped(result, 'dmesg')}"
      assert_equal 0, result.statuses['list'], name
      assert_match ROOT_ONLY, result.outputs.fetch('list'), name
    end
    # Each image is judged against its control, and each control against itself.
    control_of = controls.to_h { |name, probe| [name, probe.name] }
    verdicts = results.to_h do |name, result|
      [name, GUEST.fsck_verdict(result, control: results.fetch(control_of.fetch(name, name)))]
    end
    failed = verdicts.reject { |_name, verdict| verdict == :pass }
    assert_empty failed.keys, failed.map { |name, verdict| "#{name}: #{verdict}\n#{escaped(results.fetch(name), 'fsck')}" }.join("\n")
  end

  # Every corpus image erXos mounts, listed by Linux's ro,norecovery mount, equals erXos's
  # listing of its whole tree by erx_f2fs_listing:diff/2: names, kinds, modes, links, link
  # classes, sizes, the SHA-256 of each file's first GUEST::HASHED_BYTES and each
  # symlink's target. Linux's record of each image it mounted and listed goes to
  # NAME.linux beside the image for erx_f2fs_volume_tests:oracle_compare/1, which reads it
  # with erx_f2fs_listing:record_reader/1. The corpus is hostile, so it boots on its own.
  def test_linux_lists_the_corpus_as_erxos_does
    runner, directory = guest('corpus')
    trees = File.join(directory, 'trees')
    Dir.mkdir(trees)
    Dir.mktmpdir('erx-f2fs-oracle-erlang') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_files erx_blk erx_f2fs], tests: TESTS)
      erxos(work, 'oracle_images', trees, seconds: 60)
      images = Dir.glob(File.join(trees, '*.img')).sort.map do |path|
        GUEST::Image.new(name: File.basename(path, '.img'), path: path, origin: :foreign)
      end
      batch, = GUEST.run(root: ROOT, runner: runner, images: images, directory: directory)
      keep(directory, batch)
      assert batch.done, 'the guest did not reach its end'
      batch.results.each do |name, result|
        next unless result.statuses['mount'] == 0 && result.statuses['list'] == 0

        File.binwrite(File.join(trees, "#{name}.linux"), result.outputs.fetch('list'))
      end
      erxos(work, 'oracle_compare', trees, GUEST::HASHED_BYTES.to_s, seconds: 180)
    end
    assert_operator File.readlines(File.join(trees, 'compared.txt')).size, :>=, 2
    differences = File.binread(File.join(trees, 'differences.txt')).lines
    assert_empty differences, differences.first(40).map { |line| Erx::LineEscape.escape(line.chomp) }.join("\n")
  end

  private

  # The runner and the run's directory, build/f2fs-oracle/NAME, emptied; skips unless
  # ERX_F2FS_ORACLE=1 and the guest's pins are fetched.
  def guest(name)
    skip ORACLE_OFF unless ENV['ERX_F2FS_ORACLE'] == '1'
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    refused = GUEST.refusal(root: ROOT, runner: runner)
    skip refused if refused

    directory = File.join(ROOT, 'build/f2fs-oracle', name)
    FileUtils.rm_rf(directory)
    [runner, Erx::OutputDirectory.prepare(root: ROOT, path: directory)]
  end

  # Each step's output and the statuses beside the run, for reading after it.
  def keep(directory, batch)
    results = File.join(directory, 'results')
    Dir.mkdir(results)
    File.write(File.join(results, 'kernel'), "#{Erx::LineEscape.escape(batch.kernel.to_s)}\n")
    batch.results.each do |name, result|
      result.outputs.each { |step, bytes| File.binwrite(File.join(results, "#{name}.#{step}"), bytes) }
      File.write(File.join(results, "#{name}.statuses"), result.statuses.map { |step, code| "#{step} #{code}\n" }.join)
    end
  end

  def escaped(result, step) = Erx::LineEscape.escape(result.outputs.fetch(step, ''))

  # A volume of sectors sectors formatted by erXos's plan as a file of its own.
  def format(directory, name, sectors:, runner:)
    work = File.join(directory, "#{name}-format")
    Dir.mkdir(work)
    volume = Erx::DataVolume.f2fs(root: ROOT, runner: runner, directory: work, start: 0, sectors: sectors,
                                  version: 0x2468ace1, uuid: "\x5a".b * 16, time: 1_700_000_000)
    path = File.join(directory, "#{name}.img")
    File.open(path, 'wb') do |image|
      volume.pieces.each { |sector, bytes| image.pwrite(bytes, sector * 512) }
      image.truncate(sectors * 512)
    end
    path
  end

  # Runs erx_f2fs_volume_tests:FUNCTION on stock's emulator over the modules compiled in
  # work, the arguments reaching it as plain arguments after -extra.
  def erxos(work, function, *arguments, seconds:)
    output, status = Open3.capture2e(
      { 'ERX_F2FS_CORPUS' => File.join(ROOT, 'build/third_party'), 'ERX_DEPS_LOCK' => File.join(ROOT, 'deps.lock') },
      'gtimeout', '-k', '10', seconds.to_s, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
      "erx_f2fs_volume_tests:#{function}(init:get_plain_arguments()), halt(0).", '-extra', *arguments,
      chdir: work, stdin_data: ''
    )
    assert status.success?, Erx::LineEscape.escape(output)
  end
end
