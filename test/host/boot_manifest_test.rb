# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/manifest_context'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# What the boot information page takes from the system manifest, the same on both entries
# (docs/design-stopgap.md, "Boot information"): liberx/backend/core/boot_manifest.c over a
# manifest Manifest.admit wrote from config/manifest/qemu-virt-development.txt, driven by
# test/fixtures/boot_manifest_driver.c.
class BootManifestTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[liberx/backend/core/boot_manifest.c build/gen/liberx/generated/abi_reader.c test/fixtures/boot_manifest_driver.c].freeze
  # The fields of the source's runtime_limits system block, in the order the driver prints them.
  RUNTIME_LIMIT_FIELDS = %w[max_frame max_message_heap funnel_depth exports tmp overlay atoms foreign_atoms
                            processes].freeze

  def setup
    @directory = Dir.mktmpdir('erx-boot-manifest-')
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    @source = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))
    @driver = build
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
    output = File.join(@directory, 'driver')
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', *flags,
                                  *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, *SOURCES.map { |source| File.join(ROOT, source) },
                                  '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def admitted(source = @source, platform: 'qemu-virt')
    platform = JSON.parse(File.read(File.join(ROOT, "config/platforms/#{platform}.json")))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform, build_kind: 'development'))
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: ManifestContextFixture.accepting_planner).bytes
  end

  # hostlink: whether the boot carries erx.hostlink=1, which the driver passes on as its third argument.
  def read(bytes, stdout_path: '/pl011@9000000', hostlink: true)
    path = File.join(@directory, 'manifest.bin')
    File.binwrite(path, bytes)
    Open3.capture2e(@driver, path, stdout_path, *(hostlink ? ['hostlink'] : []), stdin_data: '')
  end

  def console_line(stdout_path)
    output, status = read(admitted, stdout_path: stdout_path)
    assert status.success?, output
    output.lines.grep(/\Aconsole /).fetch(0).chomp
  end

  # The device service's check at boot (docs/design-system.md, "Devices"): the manifest's
  # console is the node /chosen/stdout-path names, whole path against whole path.
  def test_the_console_matches_only_the_node_stdout_path_names
    assert_equal 'console /pl011@9000000 matches 1', console_line('/pl011@9000000')
    assert_equal 'console /pl011@9000000 matches 0', console_line('/pl011@9040000')
    assert_equal 'console /pl011@9000000 matches 0', console_line('/pl011@900000')
    assert_equal 'console /pl011@9000000 matches 0', console_line('/pl011@9000000/uart')
    assert_equal 'console /pl011@9000000 matches 0', console_line('')
  end

  def test_the_page_takes_the_node_the_words_and_the_limits_of_the_source
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "node system@erxos\n"
    assert_includes output, "words-- -root / -bindir /bin -progname erl -home / -boot /bin/start -user erx_console -erx console_driver erx_pl011 -nocookie -no_epmd -proto_dist erx \n"
    assert_includes output, "limits #{system_runtime_limits.join(' ')}\n"
  end

  # The root sizes its contiguous pool by the devices' memory of the whole device table,
  # whichever domain holds each: the total the packer's admission reports and counts.
  def test_the_devices_memory_is_the_total_the_packer_reports
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform, build_kind: 'development'))
    admission = Erx::Manifest.admit(source: @source, codec: @codec, context: context, planner: ManifestContextFixture.accepting_planner)
    total = admission.report.fetch('dma_memory')
    assert_operator total, :>, 0
    output, status = read(admission.bytes)
    assert status.success?, output
    assert_includes output, "dma_total #{total}\n"
  end

  def system_runtime_limits
    block = @source[/^runtime_limits system\n((?:  .*\n)*)/, 1]
    flunk 'the manifest has no runtime_limits system block' unless block
    values = block.lines.to_h { |line| line.split.first(2) }
    assert_equal RUNTIME_LIMIT_FIELDS.sort, values.keys.sort
    RUNTIME_LIMIT_FIELDS.map { |field| values.fetch(field) }
  end

  # The device records (docs/design-stopgap.md, "Device records"), in the order of the device
  # table: the host link's UART, which machine.hostlink names by its path (docs/design-live.md,
  # "The host link"), and each device of a unit the system domain holds whose role and
  # compatible string are a row of device_kinds, each with the platform record's window, line
  # DMA memory and clock. The console's UART, a UART of the same compatible string in a unit
  # the system domain holds, is no record, and the block and net units are the storage and
  # network domains', so the development manifest gives the system domain one record, the
  # host link's: erx_pl011 reads -erx console_uart, whose numbers are the console's entry.
  def test_the_hostlink_unit_gives_the_system_domain_s_one_device_record
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "console_uart 150994944 4096 33 direct 24000000\n"
    assert_includes output, "devices 1\n"
    assert_includes output, "device hostlink pl011 151257088 4096 40 direct 0 24000000 " \
                            "words-erx device hostlink pl011 151257088 4096 40 direct 24000000 exact 1 short 0\n"
    refute_match(/^device (?:block|net) /, output)
  end

  # With the net unit held by the system domain, its record follows the host link's. Net is
  # given: the root makes a window object over its transport's page, the transport at 0xe00
  # in it, and its record is -erx given with the driver's stand-in handles 11, 12 and 13 for
  # the window, line and memory objects. The host link's UART, which does no DMA, is the one
  # physical record.
  def test_a_net_unit_the_system_domain_holds_gives_a_given_record
    source = @source.sub("unit net\n  placement \"net\"\n  holder @domain.network\n",
                         "unit net\n  placement \"net\"\n  holder system\n")
    refute_equal @source, source
    output, status = read(admitted(source))
    assert status.success?, output
    assert_includes output, "devices 2\n"
    assert_includes output, "device net virtio_mmio 167783936 512 71 direct 262144 0 window 167780352 4096 3584 " \
                            "words-erx given net virtio_mmio 11 3584 512 12 direct 13 262144 0 0 0 exact 1 short 0\n"
  end

  # A given device's window object covers whole pages from the one that holds its first
  # register through the one that holds its last, and registers that are empty, wrap, or end
  # in the last page of the address space are refused rather than given a window of 0 bytes.
  # The record places the registers at the window's offset, and a device without DMA memory
  # names no memory object, whatever handle the root holds.
  def test_a_given_device_s_window_covers_the_pages_of_its_registers
    given = lambda do |window, offset, size|
      "window #{window} #{offset} words-erx given block virtio_mmio 11 #{offset} #{size} 12 direct 0 0 0 0 0 exact 1 short 0\n"
    end
    {
      %w[0xa003e00 0x200] => given.call('167784448 4096', 3584, 512),
      %w[0xfff 2] => given.call('0 8192', 4095, 2),
      %w[0x1000 0x1000] => given.call('4096 4096', 0, 4096),
      %w[0x1000 0] => "window refused\n",
      %w[0xfffffffffffffffe 4] => "window refused\n",
      %w[0xfffffffffffff000 16] => "window refused\n"
    }.each do |(base, size), expected|
      output, status = Open3.capture2e(@driver, 'window', base, size, stdin_data: '')
      assert status.success?, output
      assert_equal expected, output, "#{base} #{size}"
    end
  end

  # The host link is the boot's to ask for (docs/design-stopgap.md, "Device records"): without
  # erx.hostlink=1 its UART gives no record, so a machine with one UART, the website's, boots
  # with no host link, and the net device's record is the same either way.
  def test_the_hostlink_record_is_there_only_when_the_boot_asks_for_it
    asked, status = read(admitted, hostlink: true)
    assert status.success?, asked
    assert_match(/^device hostlink pl011 151257088 /, asked)
    plain, status = read(admitted, hostlink: false)
    assert status.success?, plain
    assert_includes plain, "devices 0\n"
    refute_match(/^device hostlink /, plain)
    assert_equal asked.lines.grep(/^device net /), plain.lines.grep(/^device net /)
  end

  # A missing disk is a normal state: a manifest with no block unit reads, and has no record.
  def test_a_manifest_without_the_block_unit_has_no_device_record
    source = @source.sub(/^unit block\n(?:  .*\n)*/, '').gsub(/^(?:window|image) \w+\n(?:  .*\n)*/, '')
    refute_equal @source, source
    output, status = read(admitted(source))
    assert status.success?, output
    assert_includes output, "devices 1\n"
    refute_match(/^device block /, output)
  end

  # The record's peripheral is a name the device NIF's table has, from the CMSIS-SVD source.
  def test_each_record_names_a_generated_peripheral
    output, status = read(admitted)
    assert status.success?, output
    table = File.read(Erx::Generated.path('include/erx/hw/device_table.h', root: ROOT))
    peripherals = output.scan(/^device \S+ (\S+) /).flatten
    refute_empty peripherals
    peripherals.each { |name| assert_includes table, %(.name = "#{name}"), name }
  end

  def test_a_manifest_with_no_system_args_gives_no_words
    output, status = read(admitted(@source.sub(/^  system_args .*\n/, '')))
    assert status.success?, output
    assert_includes output, "words\nlimits"
  end

  def test_a_word_list_in_hexadecimal_passes_as_written
    output, status = read(admitted(@source.sub(/^  system_args .*\n/, "  system_args hex:2d61006200\n")))
    assert status.success?, output
    assert_includes output, "words-a b \n"
  end

  # ERTS echoes a flag it does not know to the terminal, so these bytes would be a terminal escape.
  def test_a_word_outside_printable_ascii_is_refused
    %w[2d5a1b5d323b7265766965770700 2d5a7f00 2d5ac29b00 2d5ae280ae00].each do |word|
      output, status = read(admitted(@source.sub(/^  system_args .*\n/, "  system_args hex:#{word}\n")))
      assert_equal 1, status.exitstatus, output
      assert_equal "refused system_args_text\n", output
    end
  end

  def test_a_truncated_or_empty_manifest_is_refused_with_its_check
    bytes = admitted
    [bytes.byteslice(0, bytes.bytesize - 1), bytes.byteslice(0, 16), ''.b].each do |cut|
      output, status = read(cut)
      assert_equal 1, status.exitstatus, output
      assert_match(/\Arefused \S+/, output)
    end
  end

  def test_a_word_list_without_its_last_nul_is_refused_by_the_reader
    bytes = admitted.dup
    last = 'erx_net_erxos'
    args = bytes.index("#{last}\0".b)
    bytes.setbyte(args + last.size, 'x'.ord)
    output, status = read(bytes)
    assert_equal 1, status.exitstatus, output
    assert_match(/\Arefused /, output)
  end
  # The handoff (docs/design-stopgap.md, "The console"): the root hands the log to the console
  # when its driver maps the console's page, the one the device NIF maps for the registers. On
  # QEMU virt the PL011 starts its page; the Raspberry Pi 4's mini UART is 0x40 into its own,
  # so the page, not the registers' base, is what the driver's map names.
  def test_the_console_page_is_the_page_the_driver_maps
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "console_page 150994944\n"
    pi = File.binread(File.join(ROOT, 'config/manifest/raspi4b-development.txt'))
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "console_uart #{0xfe215040} 64 "
    assert_includes output, "console_page #{0xfe215000}\n"
  end

  def dma(role, memory, status, coherent, cpu, bus, last, mac, first, size)
    arguments = [role, memory, status, coherent, cpu, bus, last, mac, first, size].map(&:to_s)
    output, status_ = Open3.capture2e(@driver, 'dma', *arguments)
    assert status_.success?, output
    output
  end

  # The root's device step (docs/design-device-tree.md, "Facts into records"): memory only
  # where the tree gives a range and the memory's device address, which FIRST is, lies whole
  # inside the range's bus addresses; COHERENT only from a range's facts and MAC only for a
  # network row, and one console line of fixed words and the facts' numbers. Statuses are
  # erx_dt_dma_status_t's order: 0 ok, 1 no_node, 2 coherence, 3 cells, 4 malformed, 5 ranges.
  def test_the_device_step_gives_memory_only_inside_the_tree_s_range
    all = 0xffff_ffff_ffff_ffff
    window = 'window 167784448 4096 3584 words-erx given'
    assert_equal "asks 1 before none after none #{window} net virtio_mmio 11 3584 512 12 direct 13 65536 0 1 0 " \
                 "exact 1 short 0\nline erx: device tree: /virtio_mmio@a003e00: coherent 1 range 0x0 0x0 " \
                 "0xffffffffffffffff mac absent\n",
                 dma('net', 0x10000, 0, 1, 0, 0, all, 0, 0x4800_0000, 0x10000)
    # The Pi model's EMMC2, whose first GiB of CPU addresses it sees from bus address
    # 0xc0000000: memory at CPU 0x10000000 has device address 0xd0000000 and is inside.
    assert_equal "asks 1 before none after none #{window} block virtio_mmio 11 3584 512 12 direct 13 65536 0 0 0 " \
                 "exact 1 short 0\nline erx: device tree: /virtio_mmio@a003e00: coherent 0 range 0x0 0xc0000000 " \
                 "0x3fffffff\n",
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0xd000_0000, 0x10000)
    # Its CPU address as if it were the device's lies below the bus addresses, and memory that
    # runs past the last bus address, 0xffffffff, lies outside too; memory ending there is inside.
    assert_match(/\Aasks 1 before none after outside .* 12 direct 0 0 0 0 0 exact.*\nline .*: dma absent outside\n\z/,
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0x1000_0000, 0x10000))
    assert_match(/\Aasks 1 before none after outside /,
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0xffff_8000, 0x10000))
    assert_match(/\Aasks 1 before none after none .* 12 direct 13 65536 0 0 0 exact/,
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0xffff_0000, 0x10000))
    # A range whose bus addresses would pass 2^64 - 1, which the reader never gives, admits
    # no memory anywhere rather than wrapping.
    assert_match(/\Aasks 1 before none after outside /,
                 dma('block', 0x10000, 0, 0, 0, all - 0xffff, 0x3fff_ffff, 0, all - 0xffff, 0x10000))
    assert_match(/\Aasks 1 before none after outside .* 12 direct 0 0 0 1 0 exact.*\nline .*: dma absent outside\n\z/,
                 dma('block', 0x10000, 0, 1, 0, 0, 0x3fff_ffff, 0, 0x3fff_8000, 0x10000))
    assert_match(/\Aasks 1 before none after none .* 12 direct 13 65536 0 1 0 exact.*\nline .*: coherent 1 range 0x0 0x0 0x3fffffff\n\z/,
                 dma('block', 0x10000, 0, 1, 0, 0, 0x3fff_ffff, 0, 0x3fff_0000, 0x10000))
    assert_match(/\Aasks 1 before none after outside /, dma('block', 0x10000, 0, 1, 0x1000, 0x1000, all, 0, 0, 0x10000))
    assert_match(/\Aasks 1 before none after outside /,
                 dma('block', 0x10000, 0, 1, 0, 0, all, 0, 0xffff_ffff_ffff_f000, 0x10000))
    # Without a range the facts' coherence says nothing: the record is not coherent.
    %w[no_node coherence cells malformed ranges].each.with_index(1) do |reason, status|
      assert_match(/\Aasks 1 before #{reason} after none .* 12 direct 0 0 0 0 0 exact.*\nline .*: dma absent #{reason}\n\z/,
                   dma('block', 0x10000, status, 1, 0, 0, all, 0, 0, 0x10000))
    end
  end

  # MAC is the tree's address for a network row only, 48 bits with its first byte highest;
  # a network row without DMA memory asks for the address alone, and a block row without
  # DMA memory asks nothing (docs/design-device-tree.md, "What each row asks").
  def test_only_a_network_row_carries_the_tree_s_address
    all = 0xffff_ffff_ffff_ffff
    mac = 0xdca632_0102_03
    assert_match(/ direct 13 65536 0 0 #{mac} exact.*\nline .*: coherent 0 range 0x0 0x0 0xffffffffffffffff mac present\n\z/,
                 dma('net', 0x10000, 0, 0, 0, 0, all, mac, 0x4800_0000, 0x10000))
    assert_match(/ direct 13 65536 0 0 0 exact.*\nline .*: coherent 0 range 0x0 0x0 0xffffffffffffffff\n\z/,
                 dma('block', 0x10000, 0, 0, 0, 0, all, mac, 0x4800_0000, 0x10000))
    assert_match(/\Aasks 1 before none after none .* 12 direct 0 0 0 0 #{mac} exact.*\nline erx: device tree: \/virtio_mmio@a003e00: mac present\n\z/,
                 dma('net', 0, 0, 1, 0, 0, all, mac, 0, 0))
    assert_match(/\Aasks 0 before none after none .* 12 direct 0 0 0 0 0 exact/, dma('block', 0, 0, 1, 0, 0, all, mac, 0, 0))
  end

  # A line is shared when another device-tree device of the manifest names it too
  # (docs/design-shared-devices.md, "Lines inside a domain"), and each record says so
  # beside the line, so no driver decides it. On QEMU virt every line is one device's, so
  # the console's and the host link's are direct. On the Raspberry Pi 4 the mini UART's
  # line 125 is the auxiliary SPI controllers' too, and UART3's line 153 the other
  # PL011s', so the console's and the host link's records both say shared.
  def test_each_record_marks_whether_its_line_is_shared
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "console_uart 150994944 4096 33 direct 24000000\n"
    assert_includes output, "console_words-erx console_uart 150994944 4096 33 direct 24000000 exact 1 short 0\n"
    assert_match(/^device hostlink pl011 \d+ \d+ 40 direct .*words-erx device hostlink pl011 \d+ \d+ 40 direct \d+ exact 1/, output)
    pi = File.binread(File.join(ROOT, 'config/manifest/raspi4b-development.txt'))
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_match(/^console_uart #{0xfe215040} 64 125 shared \d+\n/, output)
    assert_match(/^console_words-erx console_uart #{0xfe215040} 64 125 shared \d+ exact 1 short 0\n/, output)
    assert_match(/^device hostlink pl011 \d+ \d+ 153 shared .*words-erx device hostlink pl011 \d+ \d+ 153 shared \d+ exact 1/,
                 output)
  end
end
