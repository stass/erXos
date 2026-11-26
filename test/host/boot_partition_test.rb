# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'json'
require 'rbconfig'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/boot_partition'
require_relative '../../tools/lib/erx/kernel_words'
require_relative '../../tools/lib/erx/runner'

# The Raspberry Pi 4's boot partition (Erx::BootPartition): config.txt from the platform
# record, the layout's names, its build record, and a writer that puts files only beside
# the image, in a directory under its root that holds none of its entries.
class BootPartitionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')

  # The Pi 4's card (docs/design-header-io.md, "Verification"): the firmware's settings of
  # the boot description's table first, enable_uart on every card and the ARM's JTAG on a
  # development card; BSC1's, UART3's and SPI0's pins from the header map, none for the
  # console's pins, which enable_uart sets, none for the gpio rows (GPIO 18 and 19, PWM0's,
  # among them), none for UART0's on-board pins to the Bluetooth controller, which the root
  # sets at boot; and the core clock fixed at the map's 500 MHz. The ARM's clock is left to
  # the firmware's dynamic clocking: only a bench set holds it.
  def test_config_txt_comes_from_the_record
    assert_equal %w[arm_64bit=1 kernel=kernel8.img kernel_address=0x200000 armstub=bl31.bin enable_uart=1
                    enable_jtag_gpio=1 init_uart_clock=48000000 total_mem=1024 gpu_mem=76 framebuffer_depth=32
                    framebuffer_ignore_alpha=1 max_framebuffers=1 disable_overscan=1
                    core_freq=500 core_freq_fixed=1
                    uart_2ndstage=1 dtoverlay=uart3
                    gpio=2-3=a0,pn gpio=4=a4,pn gpio=5=a4,pu gpio=7-11=a0,pn],
                 settings('development')
  end

  # A bench set holds the record's ARM clock and a card does not; both set the record's
  # memory. A record that names no clock holds none, even on a bench set.
  def test_only_a_bench_set_holds_the_arm_clock
    assert_equal({ 'arm_clock_hz' => 1_500_000_000, 'total_mem_mib' => 1024 }, Erx::BootPartition.card_settings(PI, bench: true).to_record)
    assert_equal({ 'total_mem_mib' => 1024 }, Erx::BootPartition.card_settings(PI, bench: false).to_record)
    assert_equal({ 'total_mem_mib' => 1024 }, Erx::BootPartition.card_settings(record(arm_clock_hz: nil), bench: true).to_record)
    assert_equal settings('development').insert(4, 'arm_freq=1500', 'force_turbo=1'), settings('development', bench: true)
  end

  # A release card leaves the firmware's log and the ARM's JTAG off the header: the jtag
  # rows give neither enable_jtag_gpio nor gpio= lines. Any other build kind is refused.
  def test_only_a_development_card_has_jtag
    assert_equal settings('development') - %w[uart_2ndstage=1 enable_jtag_gpio=1], settings('release')
    assert_empty set_pins(settings('release')) & [*22..27]
    error = assert_raises(Erx::Error) { config_txt(PI, overlays: [], build_kind: 'debug') }
    assert_match(/neither development nor release/, error.message)
  end

  # A map without jtag rows asks for no JTAG, even on a development card.
  def test_a_map_without_jtag_rows_gives_no_jtag
    entry, *others = PI.record.fetch('pins')
    rows = entry.fetch('rows').map { |row| row['use'] == 'jtag' ? { 'gpio' => row.fetch('gpio'), 'use' => 'reserved' } : row }
    platform = record(pins: [entry.merge('rows' => rows), *others])
    lines = config_txt(platform, overlays: [], build_kind: 'development').lines(chomp: true)
    assert_includes lines, 'uart_2ndstage=1'
    refute_includes lines, 'enable_jtag_gpio=1'
  end

  # The gpio= lines set each of the map's header device rows once and nothing else, so no
  # pin of a gpio, reserved or jtag row gets a line, and no on-board pin does: the firmware
  # leaves GPIO 30 and 31 inputs whatever config.txt says, so the root sets the on-board
  # rows at boot (docs/design-header-io.md, "On-board pins").
  def test_the_pin_lines_are_the_maps_header_device_rows
    pins = set_pins(settings('development'))
    assert_equal PI.pins.controllers.first.header_device_rows.map(&:gpio), pins
    assert_empty pins & [14, 15, *28..57]
  end

  # The pins each gpio= line sets, in order; a line may name one pin or a range
  # (gpio=7-11=...).
  def set_pins(lines)
    lines.grep(/\Agpio=/).flat_map do |line|
      first, last = line[/\Agpio=([\d-]+)=/, 1].split('-').map { |pin| Integer(pin, 10) }
      (first..(last || first)).to_a
    end
  end

  def settings(build_kind, bench: false)
    config_txt(PI, overlays: ['uart3'], build_kind: build_kind, bench: bench).lines(chomp: true).reject { |line| line.start_with?('#') }
  end

  # platform's config.txt, as a card's (bench: false) or a bench set's settings write it.
  def config_txt(platform, overlays:, build_kind:, bench: false)
    Erx::BootPartition.config_txt(platform, overlays: overlays, build_kind: build_kind,
                                            card: Erx::BootPartition.card_settings(platform, bench: bench))
  end

  # The board's RAM is the record's: total_mem less gpu_mem must be ram_bytes, so a
  # record measured at another size is refused, not written into a card that disagrees.
  def test_the_memory_config_txt_sets_is_the_records
    error = assert_raises(Erx::Error) { config_txt(record(ram_bytes: PI.record.fetch('ram_bytes') + (1 << 20)), overlays: [], build_kind: 'development') }
    assert_match(/is not total_mem 1024 MiB less gpu_mem 76 MiB/, error.message)
  end

  # config.txt takes core_freq in MHz, so a core clock of another grain is refused, and a
  # board without a header map has no card.
  def test_the_core_clock_and_the_map_are_needed_whole
    units = PI.record.fetch('units').map do |unit|
      unit.merge('devices' => unit.fetch('devices').map { |device| device['clock'] == 500_000_000 ? device.merge('clock' => 500_000_001) : device })
    end
    error = assert_raises(Erx::Error) { config_txt(record(units: units), overlays: [], build_kind: 'release') }
    assert_match(/one core clock in whole MHz/, error.message)
    error = assert_raises(Erx::Error) do
      config_txt(Erx::Platform.new(name: 'raspi4b', record: PI.record.except('pins')), overlays: [], build_kind: 'release')
    end
    assert_match(/needs the record's pins/, error.message)
  end

  def test_the_pl011s_need_one_clock
    pl011 = { 'compatible' => 'arm,pl011', 'clock' => 48_000_000 }
    units = [{ 'devices' => [pl011] }, { 'devices' => [pl011.merge('clock' => 24_000_000)] }]
    assert_raises(Erx::Error) { Erx::BootPartition.pl011_clock(record(units: units)) }
    assert_raises(Erx::Error) { Erx::BootPartition.pl011_clock(record(units: [])) }
  end

  # The firmware reads the kernel command line from cmdline.txt and the board's boot takes it
  # from /chosen/bootargs, so a development card's cmdline.txt carries the word that makes the
  # root hand the host link's UART to the system domain (design-live.md, "The host link from
  # a board"), the very word QEMU's plan adds. A release card has no cmdline.txt, so no host
  # link; any other build kind is refused.
  def test_only_a_development_card_asks_for_the_host_link
    Dir.mktmpdir do |root|
      development = plan(root)
      release = plan(root, build_kind: 'release')
      assert_equal Erx::QemuPlan::HOSTLINK_WORD, development.fetch('cmdline.txt').bytes
      assert_equal development.keys - ['cmdline.txt'], release.keys
      assert_raises(Erx::Error) { plan(root, build_kind: 'debug') }
    end
  end

  # A platform whose record names no host link UART gets no word, even on a development card.
  def test_a_platform_without_a_host_link_asks_for_none
    platform = Struct.new(:record).new(PI.record.except('hostlink'))
    assert_empty Erx::BootPartition.command_line_entry(platform, 'development')
  end

  # A bench set's words (NativeBench::BoardSets: the kernel's trace rings off) follow the
  # host link's word on one line with no newline, and a platform without the host link
  # gets them alone.
  def test_a_bench_sets_words_follow_the_host_links_word
    words = %w[erx.trace=0 erx.det=1]
    entry = Erx::BootPartition.command_line_entry(PI, 'development', words: words)
    assert_equal "#{Erx::QemuPlan::HOSTLINK_WORD} erx.trace=0 erx.det=1", entry.fetch('cmdline.txt').bytes
    platform = Struct.new(:record).new(PI.record.except('hostlink'))
    assert_equal 'erx.trace=0 erx.det=1', Erx::BootPartition.command_line_entry(platform, 'development', words: words)
                                                            .fetch('cmdline.txt').bytes
    Dir.mktmpdir do |root|
      bench = plan(root, kernel_words: Erx::KernelWords.bench)
      assert_equal "#{Erx::QemuPlan::HOSTLINK_WORD} erx.trace=0", bench.fetch('cmdline.txt').bytes, 'the plan carries the words'
      assert_equal Erx::QemuPlan::HOSTLINK_WORD, plan(root).fetch('cmdline.txt').bytes, "a card's line has the host link's word alone"
    end
  end

  def test_writes_the_layout_beside_the_image_alone
    Dir.mktmpdir do |root|
      output = File.join(root, 'image')
      Dir.mkdir(output)
      File.write(File.join(output, 'image.boot'), 'kernel')
      written = write(root, output, plan(root))
      names = %w[LICENCE.broadcom LICENSE.linux-dts LICENSE.tf-a bcm2711-rpi-4-b.dtb bcm2711-rpi-4-b.dts bl31.bin cmdline.txt config.txt fixup4.dat
                 kernel8.img overlays/uart3.dtbo start4.elf]
      files = Dir.glob('**/*', base: output).reject { |name| File.directory?(File.join(output, name)) }.sort
      assert_equal [*names.map { |name| "boot/#{name}" }, 'image.boot', 'sdcard.img', 'sdcard.img.receipt.json', 'sdcard.img.xz'].sort,
                   files
      assert_equal 'kernel', File.read(File.join(output, 'boot/kernel8.img'))
      assert_equal File.join(File.realpath(output), 'sdcard.img'), written.path
      assert_equal File.join(File.realpath(output), 'sdcard.img.xz'), written.compressed
      assert_equal %w[boot image.boot sdcard.img sdcard.img.receipt.json sdcard.img.xz], Dir.children(output).sort,
                   'no work directory is left'

      # The card is the ABI's medium, ending at its data partition of the layout's minimum
      # length, and the compressed card unpacks to it. The record partition (FAT16) is first and slot A
      # (FAT32) second. Each volume, cut out of the card, reads back through fsimg's own
      # reader and checker: the record volume holds autoboot.txt, medium_record_a, and the
      # slot volume the layout's files with the bytes the layout gave them. The raw
      # sectors agree: the record at its sector, kernel8.img at the slot's boot start, the
      # EROFS image at system A's start and the data volume at its partition's start.
      image = written.path
      assert_equal Erx::MediumImage.sectors(data_sectors: Erx::MediumImage::PACKED_DATA_SECTORS) * Erx::MediumImage::SECTOR_BYTES, File.size(image)
      assert_equal Digest::SHA256.file(image).hexdigest, unpacked_sha256(written.compressed), 'the compressed card is the card'
      assert_equal "\x55\xAA".b, File.binread(image, 2, 510)
      assert_equal [0x0e, 0x0c, 0x0c, 0x0f], (0..3).map { |index| File.binread(image, 1, 446 + (index * 16) + 4).ord }
      sector = Erx::MediumImage::SECTOR_BYTES
      slot_start = Erx::MediumImage.constant('boot_a_start') * sector
      system_start = Erx::MediumImage.constant('system_a_start') * sector
      record_volume = cut(image, root, 'record.fat', Erx::MediumImage.constant('record_start') * sector, Erx::RecordVolume::BYTES)
      slot_volume = cut(image, root, 'slot.fat', slot_start, Erx::PiMedium::SLOT_FAT_BYTES)
      fsimg('Wd', '-f', record_volume)
      assert_equal Erx::BootRecord::SLOTS.fetch(:a).text, fsimg('x', '-O', '-f', record_volume, 'autoboot.txt')
      assert_equal names.sort, fsimg('t', '-f', slot_volume).lines.map { |line| line.strip.delete('"').delete_prefix('/') }
                                                            .reject { |name| name == 'overlays' }.sort
      fsimg('Wd', '-f', slot_volume)
      assert_equal File.binread(File.join(output, 'boot/config.txt')), fsimg('x', '-O', '-f', slot_volume, 'config.txt')
      assert_equal config_txt(PI, overlays: ['uart3'], build_kind: 'development'), File.read(File.join(output, 'boot/config.txt')),
                   "a card's config.txt leaves the ARM's clock to the firmware"
      assert_equal 'kernel', fsimg('x', '-O', '-f', slot_volume, 'kernel8.img')
      assert_equal Erx::BootRecord.sector(:a), File.binread(image, sector, Erx::BootRecord::RECORD_OFFSET)
      assert_equal 'kernel', File.binread(image, 6, slot_start + Erx::PiMedium::BOOT_PLACE)
      assert_equal EROFS, File.binread(image, EROFS.bytesize, system_start + Erx::ReleaseMedium::SLOT_IMAGES_START)
      tree = Erx::AppPackage.image_tree(EROFS).bytes
      assert_equal tree, File.binread(image, tree.bytesize, system_start + Erx::ReleaseMedium::SLOT_IMAGES_START + EROFS.bytesize),
                   'the tree follows the image'
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
      repeated = write(root, again, plan(root))
      assert_equal Digest::SHA256.file(image).hexdigest, Digest::SHA256.file(repeated.path).hexdigest,
                   'the card image is the same bytes on every write'
      assert_equal Digest::SHA256.file(written.compressed).hexdigest, Digest::SHA256.file(repeated.compressed).hexdigest,
                   'the compressed card is the same bytes on every write'
    end
  end

  # The SHA-256 of the xz file at path unpacked, read as a stream.
  def unpacked_sha256(path)
    digest = Digest::SHA256.new
    Open3.popen2('xz', '-dc', path) do |input, output, wait|
      input.close
      output.binmode
      while (chunk = output.read(1 << 20))
        digest << chunk
      end
      assert wait.value.success?, "xz -dc test/host/boot_partition_test.rb failed"
    end
    digest.hexdigest
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

  # A bench set is the partition's files and their record alone: no card, volume or
  # compressed card, and a record with no card for its artifact.
  def test_a_set_is_the_partition_files_and_their_record_alone
    Dir.mktmpdir do |root|
      output = File.join(root, 'set')
      Dir.mkdir(output)
      written = Erx::BootPartition.write_set(root: root, directory: output, plan: plan(root), record: { 'inputs' => 'given' })
      assert_equal %w[boot boot.receipt.json], Dir.children(output).sort
      assert_equal [File.join(File.realpath(output), 'boot'), File.join(File.realpath(output), 'boot.receipt.json')], [written.files, written.record]
      assert_equal 'kernel', File.read(File.join(output, 'boot/kernel8.img'))
      receipt = JSON.parse(File.read(written.record))
      refute receipt.key?('artifact')
      assert_equal 'given', receipt.fetch('inputs')
      assert_equal Digest::SHA256.hexdigest('kernel'), Erx::BootPartition.listed_files(receipt).fetch('kernel8.img')
      assert_raises(Erx::Error) { Erx::BootPartition.write_set(root: root, directory: output, plan: plan(root), record: {}) }
    end
  end

  # A bench set's config.txt holds the record's ARM clock, and its build record states the
  # clock and memory that config.txt sets, from the one card write_set writes both from. A
  # plan whose config.txt is given as text is refused: it would bypass the card.
  def test_a_sets_config_txt_and_record_state_one_card
    Dir.mktmpdir do |root|
      output, given = %w[set given].map { |name| File.join(root, name).tap { |path| Dir.mkdir(path) } }
      written = Erx::BootPartition.write_set(root: root, directory: output, plan: plan(root), record: { 'inputs' => 'given' })
      card = Erx::BootPartition.card_settings(PI, bench: true)
      assert_equal config_txt(PI, overlays: ['uart3'], build_kind: 'development', bench: true),
                   File.read(File.join(written.files, 'config.txt'))
      assert_equal card.to_record, JSON.parse(File.read(written.record)).slice(*card.to_record.keys)
      error = assert_raises(Erx::Error) do
        Erx::BootPartition.write_set(root: root, directory: given, record: {},
                                     plan: plan(root).merge('config.txt' => Erx::BootPartition::Text.new("arm_freq=1800\n")))
      end
      assert_match(/config\.txt/, error.message)
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
    refute record.fetch('inputs').key?('bootable'), "the image's bootable file has its own record beside it"
    probe = { 'program' => 'header probe', 'source' => { 'path' => 'test/raspi4b/header_probe.c' } }
    assert_equal probe, Erx::BootPartition.record(root: ROOT, runner: runner, revision: revision, platform: PI,
                                                  firmware: firmware, compiler: RbConfig.ruby, linker: RbConfig.ruby,
                                                  bootable_record: probe).fetch('inputs').fetch('bootable')
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

  # A card with no release, as the header probe's is, leaves slot A's image area empty and
  # names no EROFS image in its record.
  def test_an_empty_slot_holds_no_image
    Dir.mktmpdir do |root|
      output = File.join(root, 'image')
      Dir.mkdir(output)
      written = write(root, output, plan(root), erofs: nil)
      system_start = Erx::MediumImage.constant('system_a_start') * Erx::MediumImage::SECTOR_BYTES
      empty = File.binread(written.path, EROFS.bytesize, system_start + Erx::ReleaseMedium::SLOT_IMAGES_START)
      assert_equal EROFS.bytesize, empty.count("\0")
      components = JSON.parse(File.read(written.record)).fetch('components').map { |part| part.fetch('path') }
      assert_includes components, 'data.lfs'
      refute(components.any? { |name| name.end_with?('.erofs') })
    end
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
        write(root, root, plan(root).merge('cmdline.txt' => Erx::BootPartition::Text.new("built at #{File.realpath(root)}/x\n")))
      end
      assert_match(/cmdline.txt holds the build's path/, error.message)
      assert_empty Dir.children(root).reject { |name| %w[in logs pieces].include?(name) }
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
        write(link, link, plan(link).merge('cmdline.txt' => Erx::BootPartition::Text.new("built at #{link}/x\n")))
      end
      assert_match(%r{cmdline.txt holds the build's path .*/link\z}, error.message)
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
                                       license: sources.fetch('LICENSE.linux-dts'),
                                       model: '', overlays: {})
      assert_raises(Erx::Error) do
        Erx::BootPartition.plan(platform: PI, build_kind: 'development', bootable: 'k', bl31: 'b', bl31_license: 'l', tree: tree,
                                firmware: { 'kernel8.img' => 'x' })
      end
    end
  end

# A file is bounded by the partition, not by a number of ours: the development kernel is
# 68 MB, over half of it, and packs.
def test_packs_a_bootable_file_over_half_the_partition
  Dir.mktmpdir do |root|
    output = File.join(root, 'image')
    Dir.mkdir(output)
    big = Erx::PiMedium::SLOT_FAT_BYTES / 2 + 1
    written = write(root, output, plan(root, kernel_bytes: big))
    assert_equal big, File.size(File.join(output, 'boot/kernel8.img'))
    assert File.file?(written.path)
  end
end

def test_refuses_a_file_larger_than_the_partition
  Dir.mktmpdir do |root|
    output = File.join(root, 'image')
    Dir.mkdir(output)
    too_big = Erx::PiMedium::SLOT_FAT_BYTES + 1
    error = assert_raises(Erx::Error) { write(root, output, plan(root, kernel_bytes: too_big)) }
    assert_match(/not a bounded regular file/, error.message)
    assert_empty Dir.children(output), 'nothing is left beside the image'
  end
end

# Within the read bound but over the volume: the data area starts at BOOT_PLACE, so a file
# of the partition less that cannot fit, and fsimg, not the read, refuses it.
def test_refuses_a_file_the_volume_cannot_hold
  Dir.mktmpdir do |root|
    output = File.join(root, 'image')
    Dir.mkdir(output)
    size = Erx::PiMedium::SLOT_FAT_BYTES - Erx::PiMedium::BOOT_PLACE
    error = assert_raises(Erx::CommandError) { write(root, output, plan(root, kernel_bytes: size)) }
    assert_match(/fsimg/, error.message)
    assert_empty Dir.children(output), 'nothing is left beside the image'
  end
end

  private

  FSIMG = Erx::Fsimg.locate(root: ROOT)

  # Stand-ins for the release's EROFS image and the data volume's leading blocks.
  EROFS = ('erofs' * 1000).b.ljust(8192, "\0").freeze
  VOLUME = ('littlefs' * 100).b.freeze

  def write(root, output, plan, erofs: true)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
    pieces = File.join(root, 'pieces')
    FileUtils.mkdir_p(pieces)
    erofs &&= File.join(pieces, 'release.erofs').tap { |path| File.binwrite(path, EROFS) }
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
  # kernel_bytes makes the bootable file a sparse file of that length.
  def plan(root, kernel_bytes: nil, build_kind: 'development', kernel_words: [])
    sources = File.join(root, 'in')
    FileUtils.mkdir_p(sources)
    stand_in = lambda do |name, text = name|
      File.join(sources, name).tap { |path| File.write(path, text) }
    end
    tree = Erx::BoardTree::Built.new(board: stand_in.('tree.dtb'), source: stand_in.('tree.dts'), license: stand_in.('gpl-2.0'), model: stand_in.('model.dtb'),
                                     overlays: { 'uart3' => stand_in.('uart3.dtbo') })
    firmware = %w[start4.elf fixup4.dat LICENCE.broadcom].to_h { |name| [name, stand_in.(name)] }
    bootable = stand_in.('kernel8', 'kernel')
    File.truncate(bootable, kernel_bytes) if kernel_bytes
    Erx::BootPartition.plan(platform: PI, build_kind: build_kind, bootable: bootable, bl31: stand_in.('bl31'),
                            bl31_license: stand_in.('license'),
                            tree: tree, firmware: firmware, kernel_words: kernel_words)
  end
end
