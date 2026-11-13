# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'find'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/release_medium'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'

# The packer's disk image for QEMU: the EROFS image fsimg writes, slot A's plan, and
# the medium MediumImage.release writes, read back three independent ways: the table by
# the block driver's own parser, erx_blk_table, compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies); the EROFS image inside slot A by
# fsimg, which verifies and extracts it; and every other byte by reading the file.
class ReleaseMediumTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated files the medium code reads are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  Medium = Erx::MediumImage
  Release = Erx::ReleaseMedium
  Erofs = Erx::ErofsImage
  CODEC = Erx::ABI::Generated::CODEC
  SECTOR = 512
  MIB = 1 << 20

  # A runner whose --version answers are the given first lines, for the pin's refusals.
  FakeRunner = Struct.new(:lines, :directory) do
    def run(argv, name:, **)
      log = File.join(directory, "#{name}.log")
      File.write(log, "#{lines.fetch(argv.first)}\navailable compressors: lz4\n")
      { 'log' => log }
    end
  end

  def runner(directory) = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))

  def slot_bytes = CODEC.constant('medium_slot_sectors') * SECTOR

  def file(name, length) = Release::SlotFile.new(name: name, path: "/#{name}", length: length)

  def test_the_bootable_file_starts_its_slot_where_the_layout_fixes_and_the_images_follow_aligned
    images = [file('release', (5 * MIB) + 4096), file('more', 8192)]
    plan = Release.slot_plan(boot: file('boot', 34 * MIB), images: images)
    assert_equal CODEC.constant('medium_slot_boot_start') * SECTOR, plan.boot.slot_offset
    assert_equal [['release', Release::SLOT_IMAGES_START], ['more', Release::SLOT_IMAGES_START + (6 * MIB)]],
                 plan.images.map { |extent| [extent.file.name, extent.slot_offset] }
    # The extents depend on the images alone, so the manifest can record them before the
    # boot image is packed.
    assert_equal plan.images, Release.slot_plan(boot: file('boot', 4096), images: images).images
  end

  def test_a_slot_that_cannot_hold_its_files_is_refused
    room = Release::SLOT_IMAGES_START - (CODEC.constant('medium_slot_boot_start') * SECTOR)
    assert Release.slot_plan(boot: file('boot', room), images: [])
    fits = slot_bytes - Release::SLOT_IMAGES_START
    [[room + 1, []], [0, []], [4096, [file('release', 4097)]], [4096, [file('release', fits + SECTOR)]],
     [4096, [file('release', 4096), file('release', 4096)]]].each do |boot, images|
      assert_raises(Erx::Error, [boot, images].inspect) { Release.slot_plan(boot: file('boot', boot), images: images) }
    end
    assert Release.slot_plan(boot: file('boot', 4096), images: [file('release', fits)])
  end

  def test_a_piece_outside_one_window_or_over_another_is_refused
    Dir.mktmpdir('erx-release-medium-') do |directory|
      slot_a = CODEC.constant('medium_slot_a_start')
      assert_raises(Erx::Error) { Medium.create(directory: directory, name: 'a.img', pieces: { 1 => 'x' * SECTOR }) }
      assert_raises(Erx::Error) { Medium.create(directory: directory, name: 'b.img', pieces: { slot_a - 1 => 'x' * 1024 }) }
      assert_raises(Erx::Error) do
        Medium.create(directory: directory, name: 'c.img', pieces: { slot_a => 'x' * 1024, slot_a + 1 => 'y' * SECTOR })
      end
      # A piece that runs from slot A's last sector into slot B's first lies in no one window.
      slot_b = CODEC.constant('medium_slot_b_start')
      assert_raises(Erx::Error) { Medium.create(directory: directory, name: 'd.img', pieces: { slot_b - 1 => 'x' * 1024 }) }
      # A file whose length is not the one its piece was planned with is refused, and the
      # failed write leaves nothing at the medium's name.
      short = File.join(directory, 'short')
      File.binwrite(short, 'x' * 100)
      assert_raises(Erx::Error) do
        Medium.create(directory: directory, name: 'e.img', pieces: { slot_a => Medium::FilePiece.new(path: short, length: 200) })
      end
      File.unlink(short)
      assert_empty Dir.children(directory)
    end
  end

  def test_an_image_path_must_be_plain_names_and_never_a_file_and_a_directory
    ['/etc/passwd', 'a/../b', 'a//b', '', 'a/', './a', "a\nb", 'a b'].each do |path|
      assert_raises(Erx::Error, path.inspect) { Erofs.check_files(path => '/dev/null') }
    end
    assert_raises(Erx::Error) { Erofs.check_files('lib' => '/dev/null', 'lib/a.beam' => '/dev/null') }
    assert_raises(Erx::Error) { Erofs.check_files('lib/A.beam' => '/dev/null', 'lib/a.beam' => '/dev/null') }
    assert_raises(Erx::Error) { Erofs.check_files('Lib/a.beam' => '/dev/null', 'lib/b.beam' => '/dev/null') }
    assert_raises(Erx::Error) { Erofs.check_files("#{'n' * 256}/a" => '/dev/null') }
    assert Erofs.check_files("#{'n' * 255}/a" => '/dev/null')
    assert_raises(Erx::Error) { Erofs.check_files({}) }
    assert_raises(Erx::Error) { Erx::ReleaseMedium.files([{ 'path' => 'a', 'artifact' => 'x' }, { 'path' => 'a', 'artifact' => 'y' }]) }
  end

  def test_only_the_pinned_fsimg_is_accepted
    Dir.mktmpdir('erx-release-medium-') do |directory|
      fsimg = Erx::Fsimg.locate(root: ROOT)
      assert_equal fsimg, Erofs.new(runner: FakeRunner.new({ fsimg => 'fsimg 0.1.0' }, directory)).check_tools
      ['fsimg 0.1.1', 'fsimg 0.1.0 (patched)', 'mkfs.erofs (erofs-utils) 1.9.4'].each do |line|
        error = assert_raises(Erx::Error) { Erofs.new(runner: FakeRunner.new({ fsimg => line }, directory)).check_tools }
        assert_match(/must report "fsimg 0\.1\.0"/, error.message)
      end
    end
  end

  # The release medium as the packer writes it, from a stand-in bootable file and a small
  # tree, then read back: the table by erx_blk_table, slot A's bootable file byte for
  # byte, the EROFS image by fsimg, and zeros everywhere else that was not written.
  def test_the_release_medium_reads_back_as_written
    Dir.mktmpdir('erx-release-medium-') do |directory|
      files = tree(File.join(directory, 'input'))
      boot = File.join(directory, 'image.boot')
      File.binwrite(boot, Random.new(7).bytes((3 * MIB) + 100))
      release = files.map { |path, source| { 'path' => path, 'artifact' => source } }
      first, artifacts = written(boot, release, File.join(directory, 'first'))
      second, = written(boot, release, File.join(directory, 'second'))
      extents = first.slot.images.map { |extent| { 'slot_offset' => extent.slot_offset, 'length' => extent.file.length } }
      assert_equal({ 'release' => { 'kind' => 'erofs_image', 'extents' => extents } }, artifacts,
                   'the manifest records the image where the medium holds it')

      assert_equal Digest::SHA256.file(first.path), Digest::SHA256.file(second.path), 'two writes differ'
      assert_equal Medium.sectors(data_sectors: first.data_sectors) * SECTOR, File.size(first.path)
      assert_equal Medium.windows(data_sectors: first.data_sectors).map { |window| [window.role, window.start, window.sectors] },
                   admitted(first.path)

      slot = CODEC.constant('medium_slot_a_start') * SECTOR
      image = first.slot.images.fetch(0)
      assert_equal ['release', File.size(first.erofs)], [image.file.name, image.file.length]
      File.open(first.path, 'rb') do |medium|
        assert_equal File.binread(boot), medium.pread(File.size(boot), slot + first.slot.boot.slot_offset)
        assert_equal File.binread(first.erofs), medium.pread(image.file.length, slot + image.slot_offset)
        zeros(first).each { |offset| assert_equal "\0".b * SECTOR, medium.pread(SECTOR, offset), "sector #{offset / SECTOR}" }
        # Installation formatted the data partition: its fresh volume from the first sector.
        volume = File.binread(first.volume.path)
        assert_equal volume, medium.pread(volume.bytesize, CODEC.constant('medium_data_start') * SECTOR), 'the data volume'
        assert_equal Erx::BootRecord.sector(:a), medium.pread(SECTOR, Erx::BootRecord::RECORD_OFFSET), 'the record commits slot A'
        count = (CODEC.constant('medium_record_start') + CODEC.constant('medium_record_count_start')) * SECTOR
        assert_equal "\0".b * SECTOR, medium.pread(SECTOR, count), 'the reset count is zero'
      end

      assert_equal files.transform_values { |source| File.binread(source) },
                   extract(first.path, offset: slot + image.slot_offset, directory: directory)
    end
  end

  # The image's bytes do not depend on the order the files are listed or staged in.
  def test_the_erofs_image_is_the_same_bytes_whatever_the_files_order
    Dir.mktmpdir('erx-release-medium-') do |directory|
      files = tree(File.join(directory, 'input'))
      erofs = Erofs.new(runner: runner(directory))
      outputs = [files, files.to_a.reverse.to_h].each_with_index.map do |listing, index|
        erofs.write(files: listing, name: 'release', output: File.join(directory, "#{index}.erofs"))
      end
      assert_equal(*outputs.map { |path| File.binread(path) })
      assert_equal 0, File.size(outputs.first) % 4096
    end
  end

  # Nothing of the host's metadata reaches the image: a second build under another umask,
  # from sources of other modes and times, staged a second later, gives the same bytes;
  # and an image of other files gets another UUID.
  def test_the_erofs_image_holds_nothing_of_the_hosts_metadata
    Dir.mktmpdir('erx-release-medium-') do |directory|
      files = tree(File.join(directory, 'input'))
      erofs = Erofs.new(runner: runner(directory))
      first = erofs.write(files: files, name: 'release', output: File.join(directory, 'first.erofs'))
      files.each_value.with_index do |source, index|
        File.chmod(index.even? ? 0o755 : 0o600, source)
        File.utime(100_000 * (index + 1), 100_000 * (index + 1), source)
      end
      sleep 1.1
      previous = File.umask(0o077)
      second = begin
        erofs.write(files: files, name: 'release', output: File.join(directory, 'second.erofs'))
      ensure
        File.umask(previous)
      end
      assert_equal File.binread(first), File.binread(second)
      other = files.merge('lib/extra' => files.values.first)
      digests = ->(listing) { Erofs.sources(listing).transform_values(&:digest) }
      refute_equal Erofs.uuid(digests.call(files)), Erofs.uuid(digests.call(other))
      assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, Erofs.uuid(digests.call(files)))
    end
  end

  private

  # A small release-like tree: nested directories, an empty file and a multi-block file.
  def tree(directory)
    sizes = { 'lib/kernel-10.4/ebin/kernel.beam' => 9000, 'lib/kernel-10.4/ebin/kernel.app' => 300,
              'lib/stdlib-7.0/ebin/lists.beam' => 70_000, 'lib/stdlib-7.0/include/empty.hrl' => 0,
              'releases/erxos/start.boot' => 4096, 'lib/odd#name=a\\b' => 10 }
    sizes.each_with_index.to_h do |(path, size), index|
      source = File.join(directory, index.to_s)
      FileUtils.mkdir_p(directory)
      File.binwrite(source, Random.new(index).bytes(size))
      [path, source]
    end
  end

  # The image and the medium as ProductionImage#build_medium writes them, and the
  # artifacts the image gives the manifest check.
  def written(boot, release, directory)
    FileUtils.mkdir_p(directory)
    erofs, artifacts = Erx::ReleaseMedium.image(entries: release, directory: directory, runner: runner(directory))
    built = Struct.new(:single, :erofs).new(boot, erofs)
    data_sectors = CODEC.constant('medium_data_sectors_min')
    volume = Erx::DataVolume.format(root: ROOT, owner_root: directory, runner: runner(directory), directory: directory,
                                    data_sectors: data_sectors)
    [Erx::ReleaseMedium.write(built: built, directory: directory, volume: volume, data_sectors: data_sectors), artifacts]
  end

  # The windows erx_blk_table admits from the medium's three records.
  def admitted(path)
    Dir.mktmpdir('erx-release-medium-table-') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_blk])
      script = 'Path = os:getenv("ERX_MEDIUM"), {ok, F} = file:open(Path, [read, raw, binary]), ' \
               'Records = [element(2, file:pread(F, S * 512, 512)) || {_, S} <- erx_blk_table:records()], ' \
               '{ok, W} = apply(erx_blk_table, admit, [filelib:file_size(Path) div 512 | Records]), ' \
               'io:format("~w~n", [W]), halt(0).'
      output, status = Open3.capture2e({ 'ERX_MEDIUM' => path }, 'gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'),
                                       '-noshell', '-pa', work, '-eval', script, chdir: work, stdin_data: '')
      assert status.success?, output
      output.scan(/\{(\w+),(\d+),(\d+)\}/).map { |role, start, sectors| [role.to_sym, Integer(start), Integer(sectors)] }
    end
  end

  # Byte offsets that must read as zeros: the first and last sector of every window but
  # slot A, and of slot A's gaps before, between and after its two pieces.
  def zeros(written)
    slot_a = CODEC.constant('medium_slot_a_start') * SECTOR
    image = written.slot.images.fetch(0)
    boot_start = slot_a + written.slot.boot.slot_offset
    boot_end = boot_start + written.slot.boot.file.length
    gap_start = (boot_end + SECTOR - 1) / SECTOR * SECTOR
    windows = Medium.windows(data_sectors: written.data_sectors).reject { |window| window.role == :slot_a }
    # The data window's first sector holds the fresh volume.
    starts = windows.reject { |window| window.role == :data }.map(&:start)
    [*starts.map { |start| start * SECTOR }, *windows.map { |window| window.last * SECTOR },
     slot_a, boot_start - SECTOR, gap_start, slot_a + image.slot_offset - SECTOR,
     slot_a + image.slot_offset + image.file.length, slot_a + slot_bytes - SECTOR]
  end

  # The image that starts offset bytes into path, verified by fsimg and extracted by it
  # below directory: each regular file's path inside the image and its bytes.
  def extract(path, offset:, directory:)
    fsimg = Erx::Fsimg.locate(root: ROOT)
    extracted = File.join(directory, 'extracted')
    Dir.mkdir(extracted)
    runner(directory).run([fsimg, 'W', '-f', path, "--offset=#{offset}"], name: 'fsimg-verify', deadline: 300)
    runner(directory).run([fsimg, 'xf', path, "--offset=#{offset}", '-C', extracted], name: 'fsimg-extract', deadline: 300)
    root = File.join(extracted, Dir.children(extracted).fetch(0))
    Find.find(root).select { |file| File.file?(file) }.to_h { |file| [file.delete_prefix("#{root}/"), File.binread(file)] }
  end
end
