# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'json'
require 'rbconfig'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/boot_partition'
require_relative '../../tools/lib/erx/runner'

# The Raspberry Pi 4's boot partition (Erx::BootPartition): config.txt from the platform
# record, the layout's names, its build record, and a writer that puts files only beside
# the image, in a directory under its root that holds none of its entries.
class BootPartitionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')

  def test_config_txt_comes_from_the_record
    assert_equal %w[arm_64bit=1 kernel=kernel8.img kernel_address=0x200000 armstub=bl31.bin enable_uart=1
                    init_uart_clock=48000000 total_mem=1024 gpu_mem=76 uart_2ndstage=1 enable_jtag_gpio=1
                    dtoverlay=uart3 gpio=4=a4,pn gpio=5=a4,pu],
                 settings('development')
  end

  # A release card leaves the firmware's log and the ARM's JTAG off the header; any other
  # build kind is refused.
  def test_only_a_development_card_has_jtag
    assert_equal settings('development') - %w[uart_2ndstage=1 enable_jtag_gpio=1], settings('release')
    error = assert_raises(Erx::Error) { Erx::BootPartition.config_txt(PI, overlays: [], build_kind: 'debug') }
    assert_match(/neither development nor release/, error.message)
  end

  # enable_jtag_gpio puts JTAG on GPIO 22 to 27, so no gpio line may set one of those, and
  # no two lines set one pin. enable_uart puts the console's GPIO 14 and 15 in ALT5
  # whatever a gpio line says (seen on the board), so no line names them either. A line
  # may name one pin or a range (gpio=22-27=...).
  def test_no_two_settings_take_one_pin
    pins = settings('development').grep(/\Agpio=/).flat_map do |line|
      first, last = line[/\Agpio=([\d-]+)=/, 1].split('-').map { |pin| Integer(pin, 10) }
      (first..(last || first)).to_a
    end
    assert_equal pins.uniq, pins
    assert_empty pins & [*14..15, *22..27]
  end

  def settings(build_kind)
    Erx::BootPartition.config_txt(PI, overlays: ['uart3'], build_kind: build_kind)
                      .lines(chomp: true).reject { |line| line.start_with?('#') }
  end

  # The board's RAM is the record's: total_mem less gpu_mem must be ram_bytes, so a
  # record measured at another size is refused, not written into a card that disagrees.
  def test_the_memory_config_txt_sets_is_the_records
    error = assert_raises(Erx::Error) { Erx::BootPartition.config_txt(record(ram_bytes: PI.record.fetch('ram_bytes') + (1 << 20)), overlays: [], build_kind: 'development') }
    assert_match(/is not total_mem 1024 MiB less gpu_mem 76 MiB/, error.message)
  end

  # The firmware sets no pins from an overlay, so an overlay whose pins config.txt does
  # not know is refused.
  def test_an_overlay_needs_its_pins
    assert_raises(Erx::Error) { Erx::BootPartition.config_txt(PI, overlays: ['uart5'], build_kind: 'development') }
  end

  def test_the_pl011s_need_one_clock
    pl011 = { 'compatible' => 'arm,pl011', 'clock' => 48_000_000 }
    units = [{ 'devices' => [pl011] }, { 'devices' => [pl011.merge('clock' => 24_000_000)] }]
    assert_raises(Erx::Error) { Erx::BootPartition.pl011_clock(record(units: units)) }
    assert_raises(Erx::Error) { Erx::BootPartition.pl011_clock(record(units: [])) }
  end

  def test_writes_the_layout_beside_the_image_alone
    Dir.mktmpdir do |root|
      output = File.join(root, 'image')
      Dir.mkdir(output)
      File.write(File.join(output, 'image.boot'), 'kernel')
      written = write(root, output, plan(root))
      names = %w[LICENCE.broadcom LICENCE.linux-dts LICENCE.tf-a bcm2711-rpi-4-b.dtb bcm2711-rpi-4-b.dts bl31.bin config.txt fixup4.dat
                 kernel8.img overlays/uart3.dtbo start4.elf]
      files = Dir.glob('**/*', base: output).reject { |name| File.directory?(File.join(output, name)) }.sort
      assert_equal [*names.map { |name| "boot/#{name}" }, 'image.boot', 'sdcard.img', 'sdcard.img.receipt.json'].sort, files
      assert_equal 'kernel', File.read(File.join(output, 'boot/kernel8.img'))
      assert_equal File.join(File.realpath(output), 'sdcard.img'), written.path
      assert_equal %w[boot image.boot sdcard.img sdcard.img.receipt.json], Dir.children(output).sort, 'no work directory is left'

      # The card is the ABI's medium, 2 GiB: the record partition (FAT16) first and slot A
      # (FAT32) second. Each volume, cut out of the card, reads back through fsimg's own
      # reader and checker: the record volume holds autoboot.txt, medium_record_a, and the
      # slot volume the layout's files with the bytes the layout gave them. The raw
      # sectors agree: the record at its sector, kernel8.img at the slot's boot start, the
      # EROFS image at 128 MiB into the slot and the data volume at its partition's start.
      image = written.path
      assert_equal 1 << 31, File.size(image)
      assert_equal "\x55\xAA".b, File.binread(image, 2, 510)
      assert_equal [0x0e, 0x0c, 0x0c, 0x0f], (0..3).map { |index| File.binread(image, 1, 446 + (index * 16) + 4).ord }
      sector = Erx::MediumImage::SECTOR_BYTES
      slot_start = Erx::MediumImage.constant('slot_a_start') * sector
      record_volume = cut(image, root, 'record.fat', Erx::MediumImage.constant('record_start') * sector, Erx::PiMedium::RECORD_BYTES)
      slot_volume = cut(image, root, 'slot.fat', slot_start, Erx::PiMedium::SLOT_FAT_BYTES)
      fsimg('Wd', '-f', record_volume)
      assert_equal Erx::BootRecord::SLOTS.fetch(:a).text, fsimg('x', '-O', '-f', record_volume, 'autoboot.txt')
      assert_equal names.sort, fsimg('t', '-f', slot_volume).lines.map { |line| line.strip.delete('"').delete_prefix('/') }
                                                            .reject { |name| name == 'overlays' }.sort
      fsimg('Wd', '-f', slot_volume)
      assert_equal File.binread(File.join(output, 'boot/config.txt')), fsimg('x', '-O', '-f', slot_volume, 'config.txt')
      assert_equal 'kernel', fsimg('x', '-O', '-f', slot_volume, 'kernel8.img')
      assert_equal Erx::BootRecord.sector(:a), File.binread(image, sector, Erx::BootRecord::RECORD_OFFSET)
      assert_equal 'kernel', File.binread(image, 6, slot_start + Erx::PiMedium::BOOT_PLACE)
      assert_equal EROFS, File.binread(image, EROFS.bytesize, slot_start + Erx::ReleaseMedium::SLOT_IMAGES_START)
      assert_equal VOLUME, File.binread(image, VOLUME.bytesize, Erx::MediumImage.constant('data_start') * sector)

      # The record is an assembled receipt: the card, each file of the partition by its
      # digest, and what it was given.
      record = JSON.parse(File.read(written.record))
      assert_equal 'given', record.fetch('inputs')
      assert_equal({ 'path' => 'sdcard.img', 'sha256' => Digest::SHA256.file(image).hexdigest }, record.fetch('artifact'))
      assert_equal [*names.sort.map { |name| "boot/#{name}" }, 'data.lfs', 'release.erofs'],
                   record.fetch('components').map { |part| part.fetch('path') }
      assert_includes record.fetch('components'), { 'path' => 'boot/kernel8.img', 'sha256' => Digest::SHA256.hexdigest('kernel') }
      assert_includes record.fetch('components'), { 'path' => 'release.erofs', 'sha256' => Digest::SHA256.hexdigest(EROFS) }
      assert_includes record.fetch('components'), { 'path' => 'data.lfs', 'sha256' => Digest::SHA256.hexdigest(VOLUME) }

      # The same layout written again is the same bytes.
      again = File.join(root, 'again')
      Dir.mkdir(again)
      assert_equal Digest::SHA256.file(image).hexdigest, Digest::SHA256.file(write(root, again, plan(root)).path).hexdigest,
                   'the card image is the same bytes on every write'
    end
  end

  def test_refuses_to_write_outside_its_root
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |elsewhere|
        assert_raises(Erx::Error) { write(root, elsewhere, plan(root)) }
        assert_empty Dir.children(elsewhere)
        File.symlink(elsewhere, File.join(root, 'link'))
        assert_raises(Erx::Error) { write(root, File.join(root, 'link'), plan(root)) }
        assert_empty Dir.children(elsewhere)
      end
      ['../escape', 'overlays/../../escape', '/tmp/escape', 'a/b', 'overlays/'].each do |name|
        assert_raises(Erx::Error, name) { write(root, root, { name => Erx::BootPartition::Text.new('') }) }
      end
      refute File.exist?(File.join(root, 'escape'))
    end
  end

  # A directory that already holds one of the medium's entries, or a link by its name, is
  # refused and left as it was: the medium is written only beside a fresh image.
  def test_refuses_a_directory_that_holds_one_of_its_entries
    Erx::BootPartition::ENTRIES.each do |entry|
      Dir.mktmpdir do |root|
        output = File.join(root, 'image')
        Dir.mkdir(output)
        File.write(File.join(output, entry), 'keep')
        assert_raises(Erx::Error, entry) { write(root, output, plan(root)) }
        assert_equal [entry], Dir.children(output)
        assert_equal 'keep', File.read(File.join(output, entry))
      end
    end
    Dir.mktmpdir do |root|
      File.symlink('/nonexistent', File.join(root, 'boot'))
      assert_raises(Erx::Error) { write(root, root, plan(root)) }
    end
  end

  # The record names every input by its pin or digest: the firmware as deps.lock pins
  # it, BL31's own build record, TF-A's license, the board tree's source, recipe and
  # overlays, and fsimg with its arguments. It is published with the card, so it names
  # the commit the card was built from in full, each host tool is named by its version
  # line, and nothing in it is an absolute path.
  def test_the_record_names_the_inputs
    firmware = Erx::BootPartition::FIRMWARE.map { |id| { 'id' => id } }
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    commit = '0123456789abcdef0123456789abcdef01234567'
    revision = Erx::SourceRevision::Revision.new(count: 42, hash: commit[0, 12], commit: commit, dirty: true,
                                                 committed_at: Time.utc(2026, 11, 12))
    record = Erx::BootPartition.record(root: ROOT, runner: runner, revision: revision, platform: PI, firmware: firmware,
                                       compiler: RbConfig.ruby, linker: RbConfig.ruby)
    assert_same record, Erx::BootPartition.check_record(record)
    assert_equal({ 'commit' => commit, 'dirty' => true }, record.fetch('source'))
    assert_nil Erx::BootPartition.record(root: ROOT, runner: runner, revision: nil, platform: PI, firmware: firmware,
                                         compiler: RbConfig.ruby, linker: RbConfig.ruby).fetch('source')
    refute_includes JSON.generate(record), Dir.home, "the record names no path in the user's home"
    assert_equal 'tools/lib/erx/boot_partition.rb', record.fetch('producer').fetch('path')
    record = record.fetch('inputs')
    assert_equal firmware, record.fetch('firmware')
    assert_equal 'trusted-firmware-a', record.fetch('bl31').fetch('source').fetch('id')
    ruby = "ruby #{RUBY_VERSION}"
    assert_match(/\A#{Regexp.escape(ruby)}/, record.fetch('bl31').fetch('compiler'))
    assert_match(/\A#{Regexp.escape(ruby)}/, record.fetch('bl31').fetch('linker'))
    assert_equal({ 'source' => 'trusted-firmware-a', 'path' => 'docs/license.rst' }, record.fetch('bl31_license'))
    tree = record.fetch('board_tree')
    assert_equal 'linux-dts', tree.fetch('source').fetch('id')
    assert_equal 'tools/lib/erx/board_tree.rb', tree.fetch('recipe').fetch('path')
    assert_match(/\A#{Regexp.escape(ruby)}/, tree.fetch('compiler'))
    assert_match(/DTC \d/, tree.fetch('dtc'))
    assert_equal({ 'path' => 'hw/dts/raspi4b-uart3.dtso',
                   'sha256' => Digest::SHA256.file(File.join(ROOT, 'hw/dts/raspi4b-uart3.dtso')).hexdigest },
                 tree.fetch('overlays').fetch('uart3'))
    assert_equal Erx::Fsimg::VERSION_LINE, record.fetch('card').fetch('tool')
    assert_equal({ 'kernel8.img' => 4 << 20 }, record.fetch('card').fetch('arguments').fetch('slot').fetch('place'))
  end

  # Seeded faults: an absolute path anywhere in a record, as a value, a key or inside a
  # version line, after a separator or as a file URL, is refused, and the error names
  # where it is without repeating it; a URL and a relative path are not paths of the host.
  def test_a_record_that_names_an_absolute_path_is_refused
    good = { 'url' => 'https://cdn.kernel.org/pub/x.tar.xz', 'path' => 'tools/lib/erx/boot_partition.rb',
             'tool' => 'Homebrew clang version 21.1.5 (based on LLVM 21.1.5)' }
    assert_same good, Erx::BootPartition.check_record(good)
    [{ 'compiler' => '/Users/someone/llvm/bin/clang' }, { 'a' => [{ 'b' => 'clang version 22 (/home/someone/llvm)' }] },
     { '/Users/someone/bin/dtc' => 'Version: DTC 1.7.2' }, { 'flags' => '--sysroot=/Users/someone/sdk' },
     { 'path' => 'PATH:/Users/someone/bin' }, { 'url' => 'file:///Users/someone/x' },
     { 'list' => "['/Users/someone/x']" }, { 'home' => '~/someone/llvm' }, { 'bidi' => "someone\u202e" },
     { 'escape' => "someone\e[31m" }].each do |bad|
      error = assert_raises(Erx::Error, bad.inspect) { Erx::BootPartition.check_record(good.merge(bad)) }
      refute_includes error.message, 'someone', "#{bad.inspect}: the error does not repeat the path"
    end
    error = assert_raises(Erx::Error) { Erx::BootPartition.check_record(good.merge('a' => [{ 'b' => '/Users/x' }])) }
    assert_match(%r{in "a/0/b"\z}, error.message)
  end

  # A file that holds the path the tree was built at would carry the build host into the
  # card and make its bytes depend on where it was built, so it is refused.
  def test_refuses_a_file_that_names_the_build_path
    Dir.mktmpdir do |root|
      error = assert_raises(Erx::Error) do
        write(root, root, { 'config.txt' => Erx::BootPartition::Text.new("built at #{File.realpath(root)}/x\n") })
      end
      assert_match(/config.txt holds the build's path/, error.message)
      assert_empty Dir.children(root).reject { |name| %w[logs pieces].include?(name) }
    end
  end

  # The tree's path as the build spelled it, through a symbolic link, is refused too.
  def test_refuses_the_build_path_spelled_through_a_link
    Dir.mktmpdir do |scratch|
      tree = File.join(scratch, 'tree')
      Dir.mkdir(tree)
      link = File.join(scratch, 'link')
      File.symlink(tree, link)
      error = assert_raises(Erx::Error) do
        write(link, link, { 'config.txt' => Erx::BootPartition::Text.new("built at #{link}/x\n") })
      end
      assert_match(%r{config.txt holds the build's path .*/link\z}, error.message)
    end
  end

  # The tree's path matches only where it starts a path: a tree at /src is not named by
  # kernel/src/, nor one at /x/tree by /x/tree-old/.
  def test_the_build_path_matches_only_as_a_whole_path
    Dir.mktmpdir do |scratch|
      tree = File.realpath(scratch)
      assert_nil Erx::BuildPath.find_in("fiasco#{tree}/kernel.h\0#{tree}-old/x\0#{tree}", root: tree)
      assert_equal tree, Erx::BuildPath.find_in("x\0#{tree}/littlefs/lfs.c\0", root: tree)
    end
  end

  def test_refuses_a_firmware_file_that_would_replace_one_of_its_own
    Dir.mktmpdir do |root|
      sources = plan(root)
      tree = Erx::BoardTree::Built.new(board: sources.fetch('bcm2711-rpi-4-b.dtb'), source: sources.fetch('bcm2711-rpi-4-b.dts'),
                                       license: sources.fetch('LICENCE.linux-dts'),
                                       model: '', overlays: {})
      assert_raises(Erx::Error) do
        Erx::BootPartition.plan(platform: PI, build_kind: 'development', bootable: 'k', bl31: 'b', bl31_license: 'l', tree: tree,
                                firmware: { 'kernel8.img' => 'x' })
      end
    end
  end

  private

  FSIMG = Erx::Fsimg.locate(root: ROOT)

  # Stand-ins for the release's EROFS image and the data volume's leading blocks.
  EROFS = ('erofs' * 1000).b.ljust(8192, "\0").freeze
  VOLUME = ('littlefs' * 100).b.freeze

  def write(root, output, plan)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
    pieces = File.join(root, 'pieces')
    FileUtils.mkdir_p(pieces)
    erofs = File.join(pieces, 'release.erofs').tap { |path| File.binwrite(path, EROFS) }
    volume = File.join(pieces, 'data.lfs').tap { |path| File.binwrite(path, VOLUME) }
    Erx::BootPartition.write(root: root, directory: output, plan: plan, record: { 'inputs' => 'given' }, runner: runner,
                             fsimg: FSIMG, erofs: erofs, volume: Erx::MediumImage::FilePiece.new(path: volume, length: VOLUME.bytesize))
  end

  # The bytes of image from offset, length long, written as name in root.
  def cut(image, root, name, offset, length)
    File.join(root, name).tap { |path| File.binwrite(path, File.binread(image, length, offset)) }
  end

  # fsimg's standard output for arguments, which must succeed.
  def fsimg(*arguments)
    output, status = Open3.capture2(FSIMG, *arguments, stdin_data: '', binmode: true)
    assert status.success?, "fsimg #{arguments.join(' ')} failed"
    output
  end

  def record(**fields) = Erx::Platform.new(name: 'raspi4b', record: PI.record.merge(fields.transform_keys(&:to_s)))

  # A plan over stand-in files in root/in.
  def plan(root)
    sources = File.join(root, 'in')
    FileUtils.mkdir_p(sources)
    stand_in = lambda do |name, text = name|
      File.join(sources, name).tap { |path| File.write(path, text) }
    end
    tree = Erx::BoardTree::Built.new(board: stand_in.('tree.dtb'), source: stand_in.('tree.dts'), license: stand_in.('gpl-2.0'), model: stand_in.('model.dtb'),
                                     overlays: { 'uart3' => stand_in.('uart3.dtbo') })
    firmware = %w[start4.elf fixup4.dat LICENCE.broadcom].to_h { |name| [name, stand_in.(name)] }
    Erx::BootPartition.plan(platform: PI, build_kind: 'development', bootable: stand_in.('kernel8', 'kernel'), bl31: stand_in.('bl31'),
                            bl31_license: stand_in.('license'),
                            tree: tree, firmware: firmware)
  end
end
