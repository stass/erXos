# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/platform'
require_relative '../fixtures/manifest_context'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/fuzz/manifest_seeds'

# erx-gate: sanitizers

# What the boot information page takes from the system manifest, the same on both entries
# (docs/design-fiasco.md, "Boot information"): liberx/backend/core/boot_manifest.c over a
# manifest Manifest.admit wrote from QEMU virt's development manifest, driven by
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
    @source = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
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

  # record: the platform record, by default the named platform's own; device_kinds: the
  # check's device kinds, by default the tree's.
  def admitted(source = @source, **options) = admission(source, **options).bytes

  # The check's admission of source, its bytes and its report.
  def admission(source = @source, platform: 'qemu-virt', record: platform_record(platform),
                device_kinds: ManifestContextFixture.device_kinds)
    arguments = ManifestContextFixture.arguments(@codec).merge(platform: record, build_kind: 'development',
                                                                 device_kinds: device_kinds)
    context = Erx::Manifest::Context.new(**arguments)
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: ManifestContextFixture.accepting_planner)
  end

  def platform_record(platform) = Erx::Platform.load(root: ROOT, name: platform).record

  # The firmware request rows bytes packs, each as its name, its device's path, its tag and
  # its two argument words.
  def firmware_rows(bytes)
    offset, count = bytes.byteslice(480, 8).unpack('L<L<')
    devices_offset = bytes.byteslice(256, 4).unpack1('L<') # the header's devices span
    strings_offset = bytes.byteslice(360, 4).unpack1('L<') # and its strings span
    (0...count).map do |row|
      name_offset, name_length, device, tag, *arguments = bytes.byteslice(offset + (row * 24), 24).unpack('L<6')
      path_offset, path_length = bytes.byteslice(devices_offset + (device * 104) + 8, 8).unpack('L<L<')
      [bytes.byteslice(strings_offset + name_offset, name_length), bytes.byteslice(strings_offset + path_offset, path_length), tag, *arguments]
    end
  end

  # The packer refuses the Pi 4's record with its firmware requests changed as the block says;
  # the refusal.
  def assert_firmware_requests_refused(source)
    record = platform_record('raspi4b')
    rows = yield(record.fetch('firmware_requests'))
    error = assert_raises(Erx::Manifest::Invalid) { admitted(source, platform: 'raspi4b', record: record.merge('firmware_requests' => rows)) }
    assert_equal 'context.platform.firmware_requests', error.field
    error
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

  # The system domain's declaration (docs/design-system.md, "The declaration"), as the page
  # prints it: the key, each service's name and interface number, then its --.
  DECLARATION = '-erx_serves (?:[a-z_0-9]+ [0-9]+ )+-- '

  def test_the_page_takes_the_node_the_words_and_the_limits_of_the_source
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "node system@erxos\n"
    assert_match(%r{^words-- #{DECLARATION}-root / -bindir /bin -progname erl -home / -boot /bin/start -user erx_console -nocookie -no_epmd -proto_dist erx \n}, output)
    assert_includes output, "limits #{system_runtime_limits.join(' ')}\n"
  end

  # The root sizes its contiguous pool by the devices' memory of the whole device table,
  # whichever domain holds each: the total the manifest check reports and counts.
  def test_the_devices_memory_is_the_total_the_packer_reports
    platform = platform_record('qemu-virt')
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

  # The device records (docs/design-fiasco.md, "Device records"), in the order of the device
  # table: the host link's UART, which machine.hostlink names by its path (docs/design-live.md,
  # "The host link"), and each device of a unit the system domain holds whose role and
  # compatible string are a row of device_kinds, each with the platform record's window, line
  # DMA memory and clock. The console's UART, a UART of the same compatible string in a unit
  # the system domain holds, is no record, and the block and net units are the storage and
  # network domains', so the development manifest gives the system domain two records, the
  # host link's and the PL031's, a given record of the rtc unit it holds, which erx_rtc_pl031
  # reads: erx_pl011 reads -erx_record console pl011, whose numbers are the console's entry.
  def test_the_hostlink_and_rtc_units_give_the_system_domain_s_device_records
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "console_uart pl011 150994944 4096 33 direct 24000000\n"
    assert_includes output, "devices 2\n"
    # The given record's last number is the device's manifest row: units pack sorted by name,
    # so the pcie unit's host bridge row comes before the rtc unit's.
    assert_includes output, "device rtc pl031 151060480 4096 34 direct 0 0 window 151060480 4096 0 " \
                            "words-erx_record given rtc pl031 /pl031@9010000 11 0 4096 12 direct 0 0 0 0 0 13 exact 1 short 0\n"
    assert_includes output, "device hostlink pl011 151257088 4096 40 direct 0 24000000 " \
                            "words-erx_record device hostlink pl011 /pl011@9040000 151257088 4096 40 direct 24000000 10 0 0 exact 1 short 0\n"
    refute_match(/^device (?:block|net) /, output)
  end

  # The application controller reads each flag named after an application as that
  # application's environment, every word a term (otp/lib/kernel/src/application_controller.erl,
  # get_cmd_env), and a record's PATH such as /pl011@9040000 is no term. So the records ride
  # on a flag no application is named after: a stock node given the console and device
  # records the root writes loads an application erx with no environment.
  def test_no_record_word_becomes_application_environment
    output, status = read(admitted)
    assert status.success?, output
    words = output.scan(/words(\S.*?) exact \d/).flat_map { |(text)| text.split(' ') }
    assert_includes words, '/pl011@9040000'
    probe = 'io:format("~p~n", [{application:load({application, erx, [{vsn, "0"}, {modules, []}, ' \
            '{registered, []}, {applications, [kernel, stdlib]}]}), application:get_all_env(erx)}]), halt().'
    result, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', *words,
                                     '-eval', probe, stdin_data: '')
    assert status.success?, result
    assert_equal "{ok,[]}\n", result.lines.last
  end

  # The flag stays apart from every application's name, erXos's and OTP's, and no shipped
  # manifest writes a record in its system_args: the console's record is the root's.
  def test_the_record_flag_names_no_application_and_no_manifest_writes_a_record
    flag = @codec.fixed_bytes('boot_record_flag')
    applications = Dir.glob(File.join(ROOT, '{erlang/apps,otp/lib}/*/src/*.app.src')).map { |path| File.basename(path, '.app.src') }
    assert_includes applications, 'erx'
    refute_includes applications, flag
    Dir.glob(File.join(ROOT, 'config/manifest/*.txt')).each do |path|
      File.read(path).scan(/^  system_args "(.*)"$/).flatten.each do |args|
        refute_match(/(?:\A| )-#{Regexp.escape(flag)}(?: |\z)/, args, path)
      end
    end
  end

  # A record's PATH is its device's device-tree path, which reaches its driver and may be
  # printed, so the root refuses a manifest whose recorded device has a path that is not a
  # node path: the manifest check accepts none, and these bytes are the accepted ones with the
  # host link's path given a byte no node name holds.
  def test_a_recorded_device_s_path_must_be_a_node_path
    bytes = admitted
    refute_empty bytes.scan('/pl011@9040000')
    output, status = read(bytes.gsub('/pl011@9040000', "/pl011@9040#00"))
    assert_equal 1, status.exitstatus, output
    assert_equal "refused device_path\n", output
  end

  # With the net unit held by the system domain, its record follows the host link's. Net is
  # given: the root makes a window object over its transport's page, the transport at 0xe00
  # in it, and its record is -erx_record given with the driver's stand-in handles 11, 12 and 13 for
  # the window, line and memory objects. The host link's UART, which does no DMA, is the one
  # physical record.
  def test_a_net_unit_the_system_domain_holds_gives_a_given_record
    source = @source.sub("unit net\n  placement \"net\"\n  holder @domain.network\n",
                         "unit net\n  placement \"net\"\n  holder system\n")
    refute_equal @source, source
    output, status = read(admitted(source))
    assert status.success?, output
    assert_includes output, "devices 3\n"
    assert_includes output, "device net virtio_net 167783936 512 71 direct 262144 0 window 167780352 4096 3584 " \
                            "words-erx_record given net virtio_net /virtio_mmio@a002e00 11 3584 512 12 direct 13 262144 0 0 0 11 exact 1 short 0\n"
  end

  # A given device's window object covers whole pages from the one that holds its first
  # register through the one that holds its last, and registers that are empty, wrap, or end
  # in the last page of the address space are refused rather than given a window of 0 bytes.
  # The record places the registers at the window's offset, and a device without DMA memory
  # names no memory object, whatever handle the root holds.
  def test_a_given_device_s_window_covers_the_pages_of_its_registers
    given = lambda do |window, offset, size|
      "window #{window} #{offset} words-erx_record given block virtio_mmio /virtio_mmio@a003e00 11 #{offset} #{size} 12 direct 0 0 0 0 0 0 exact 1 short 0\n"
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

  # The host link is the boot's to ask for (docs/design-fiasco.md, "Device records"): without
  # erx.hostlink=1 its UART gives no record, so a machine with one UART, the website's, boots
  # with no host link, and the net device's record is the same either way.
  def test_the_hostlink_record_is_there_only_when_the_boot_asks_for_it
    asked, status = read(admitted, hostlink: true)
    assert status.success?, asked
    assert_match(/^device hostlink pl011 151257088 /, asked)
    plain, status = read(admitted, hostlink: false)
    assert status.success?, plain
    assert_includes plain, "devices 1\n"
    refute_match(/^device hostlink /, plain)
    assert_equal asked.lines.grep(/^device net /), plain.lines.grep(/^device net /)
  end

  # The line grant's UART (docs/design-bluetooth.md, "The controller's line"): the one PL011
  # the grant's uart names, by its device row's index, gives the record of role line, whose
  # last word is that index, by which the line service matches its grant to it. The other
  # UART of a unit the system domain holds, line_b, which no grant names, gives none.
  def test_the_root_writes_the_line_s_record_for_its_uart_only
    bytes = Erx::ManifestSeeds.line_grant(ROOT, @codec)
    view = @codec.open('manifest', bytes)
    paths = view.count('devices').times.map { |index| view.string(view.fetch('devices', index).fetch('path')) }
    output, status = read(bytes)
    assert status.success?, output
    records = output.lines.grep(/^device line /)
    assert_equal 1, records.size, output
    words = "words-erx_record device line pl011 /pl011@9050000 #{0x9050000} 4096 41 direct 24000000 " \
            "#{paths.index('/pl011@9050000')} 0 0 exact"
    assert_includes records.first, words
    refute_includes output, '/pl011@9060000'
  end

# The line's record carries its device's power line times (docs/design-bluetooth.md, "The
# power line"): with a power row naming the line's UART, its record's last two words are
# the row's off and on milliseconds, which the line service waits. A time erx_mf_device's
# u16 fields cannot hold is refused at the packer.
def test_the_line_s_record_carries_its_device_s_power_line_times
  grant = ManifestContextFixture.line_grant('line', '@domain.alpha', Erx::ManifestSeeds::LINE_UART,
                                            floor: @codec.constant('files_max_frame_min'))
  source = ManifestContextFixture.with_line(ManifestContextFixture.domain_source(@source), grant)
  power = { 'device' => '/pl011@9050000', 'power_line' => 'bt_power', 'off_ms' => 300, 'on_ms' => 500 }
  record = ManifestContextFixture.line_platform(platform_record('qemu-virt')).merge('firmware_requests' => [power])
  bytes = admitted(source, record: record)
  view = @codec.open('manifest', bytes)
  paths = view.count('devices').times.map { |index| view.string(view.fetch('devices', index).fetch('path')) }
  output, status = read(bytes)
  assert status.success?, output
  assert_includes output.lines.grep(/^device line /).first,
                  "words-erx_record device line pl011 /pl011@9050000 #{0x9050000} 4096 41 direct 24000000 " \
                  "#{paths.index('/pl011@9050000')} 300 500 exact"
  assert_raises(Erx::Error) { admitted(source, record: record.merge('firmware_requests' => [power.merge('on_ms' => 65_536)])) }
end

# The Raspberry Pi 4's power row puts its times on UART0's device row alone, the one device
# with a power line; every other row carries 0 and 0.
def test_the_raspberry_pi_s_power_row_times_are_uart0_s_device_row_s
  pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
  view = @codec.open('manifest', admitted(pi, platform: 'raspi4b'))
  powered = view.count('devices').times.map { |index| view.fetch('devices', index) }
                .reject { |row| row.values_at('power_off_ms', 'power_on_ms') == [0, 0] }
                .map { |row| [view.string(row.fetch('path')), row.fetch('power_off_ms'), row.fetch('power_on_ms')] }
  assert_equal [['/soc/serial@7e201000', 300, 500]], powered
end

# The Raspberry Pi 4's development manifest runs the Bluetooth domain on the board's
# controller (docs/design-bluetooth.md, "The Bluetooth domain", "The controller's line"):
# its one line grant names UART0 at 115200 with RTS/CTS flow, and the root writes UART0's
# line record, which carries the power row's times, from the host link's unit, which the
# system domain holds.
def test_the_raspberry_pi_s_development_manifest_grants_uart0_s_line_to_the_bluetooth_domain
  pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
  facets = Erx::Manifest::Frontend.read(pi).records.fetch('facet').select { |row| row.reference('service') == '@service.line' }
  assert_equal ['@domain.bt'], facets.map { |row| row.reference('grantee') }
  parameters = facets.first.to_h.fetch(:parameters).to_h { |key, value| [key.value, value.value] }
  assert_equal({ 'device' => '/soc/serial@7e201000', 'rate' => '115200', 'flow' => 'rts_cts' }, parameters)
  bytes = admitted(pi, platform: 'raspi4b')
  view = @codec.open('manifest', bytes)
  paths = view.count('devices').times.map { |index| view.string(view.fetch('devices', index).fetch('path')) }
  output, status = read(bytes, stdout_path: '/soc/serial@7e215040')
  assert status.success?, output
  records = output.lines.grep(/^device line /)
  assert_equal 1, records.size, output
  # UART0's 512-byte register window and its interrupt line, 153, shared with the host link.
  assert_includes records.first, "words-erx_record device line pl011 /soc/serial@7e201000 #{0xfe20_1000} 512 153 "
  assert_includes records.first, " #{paths.index('/soc/serial@7e201000')} 300 500 "
end

  # A missing disk is a normal state: a manifest with no block unit, and so no windows, no
  # system_image row, none of the services the windows' holder serves from them, and no
  # apps row, which needs the system tree (property 19), reads, and has no record.
  def test_a_manifest_without_the_block_unit_has_no_device_record
    source = Erx::Manifest::Edit.without_apps(@source).sub(/^unit block\n(?:  .*\n)*/, '')
                                                      .gsub(/^(?:window|image) \w+\n(?:  .*\n)*|^system_image\n(?:  .*\n)*/, '')
                                                      .gsub(/^(?:service system|service login_keys|service media|facet media|facet login_keys|facet login_keys_session)\n(?:  .*\n)*/, '')
    refute_equal @source, source
    output, status = read(admitted(source))
    assert status.success?, output
    assert_includes output, "devices 2\n"
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

  def test_a_manifest_with_no_system_args_gives_the_declaration_alone
    output, status = read(admitted(@source.sub(/^  system_args .*\n/, '')))
    assert status.success?, output
    assert_match(/^words-- #{DECLARATION}\nlimits/, output)
  end

  def test_a_word_list_in_hexadecimal_passes_as_written
    output, status = read(admitted(@source.sub(/^  system_args .*\n/, "  system_args hex:2d61006200\n")))
    assert status.success?, output
    assert_match(/^words-a b -- #{DECLARATION}\n/, output)
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
  # The Raspberry Pi 4's console is the mini UART, whose registers start 0x40 into their page:
  # the console record names the registers' base, not the page's.
  def test_the_raspberry_pi_console_is_the_mini_uart_at_its_registers
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "console_uart mini_uart #{0xfe215040} 64 "
  end

  # A console UART of a compatible string no row of erx/device_kinds.h's erx_uart_kinds names
  # would get no console record, and its boot would end with the console's no_console, so
  # the check refuses it and names the string. Its clock is 0, as a row of no clocked kind's is.
  def test_a_console_of_no_uart_kind_is_refused_at_the_check
    record = platform_record('qemu-virt')
    console = record.fetch('units').flat_map { |unit| unit.fetch('devices') }
                    .find { |device| device.fetch('path') == record.fetch('console') }
    console.merge!('compatible' => 'ns16550a', 'clock' => 0)
    error = assert_raises(Erx::Manifest::Invalid) { admitted(record: record) }
    assert_includes error.message, 'ns16550a'
    assert_equal 'machine.console', error.field
  end

  # The header's msi_frame (offset 456: base u64, first u32, count u32) is the platform
  # record's, and zero for a platform without one.
  def test_the_header_carries_the_platform_s_msi_frame
    assert_equal [0x0802_0000, 80, 64], admitted.byteslice(456, 16).unpack('Q<L<L<')
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    assert_equal [0, 0, 0], admitted(pi, platform: 'raspi4b').byteslice(456, 16).unpack('Q<L<L<')
  end

  # The header's firmware_requests span (offset 480: offset u32, count u32) names the platform
  # record's rows of placed devices, each name (offset u32, length u32), device row u32, tag
  # u32 and two argument words u32, 0 past the tag's request (abi/manifest.txt,
  # erx_mf_firmware_request); QEMU virt's record has none. The Pi 4's are the VL805's
  # notification, index 0 of its PCIe bridge's row, and UART0's power row as two rows of
  # UART0's device: bt_off, SET_GPIO_STATE with pin 128 and state 0, at index 0, and bt_on,
  # state 1, at index 1 (docs/design-bluetooth.md, "The power line").
  def test_the_firmware_requests_are_the_platform_record_s_rows
    assert_equal 0, admitted.byteslice(480, 8).unpack1('x4L<')
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    assert_equal [['vl805_notify', '/scb/pcie@7d500000', 0x0003_0058, 0x0010_0000, 0],
                  ['bt_off', '/soc/serial@7e201000', 0x0003_8041, 128, 0],
                  ['bt_on', '/soc/serial@7e201000', 0x0003_8041, 128, 1]], firmware_rows(admitted(pi, platform: 'raspi4b'))
  end

  # The header's pins span (offset 488: offset u32, count u32) names the pin table's rows
  # (abi/manifest.txt, erx_mf_pin, 48 bytes): each pin's rows in pin order, with its pin,
  # owner (mf_none for plain GPIO), the controller's device row, function (plain 0,
  # alternate 1), alternate, pull (keep 0, none 1, up 2), level and uses (none 0, normal 1,
  # rescue 2). QEMU virt's record has no pins. The Pi 4's firmware rows, the console's GPIO
  # 14 and 15 and JTAG's 22 to 27, and its reserved GPIO 0 and 1 have none, and nor have
  # BSC1's GPIO 2 and 3 or SPI0's 7 to 11, whose units the manifest does not place
  # (docs/design-pinctrl.md, "What is generated from it"). UART3, the host link, is the
  # system release's, so rescue uses it; UART0 is the Bluetooth domain's by its line grant,
  # and that domain is not marked for rescue.
  def test_the_pins_rows_are_the_pin_table_s
    assert_equal 0, admitted.byteslice(488, 8).unpack1('x4L<')
    gpio = ->(pin) { [pin, 0xffff_ffff, :controller, 0, 0, 0, 0, 0] }
    device = ->(pin, alternate, pull, uses) { [pin, :device, :controller, 1, alternate, pull, 0, uses] }
    expected = [device.(4, 4, 1, 2), device.(5, 4, 2, 2), gpio.(6), gpio.(12), gpio.(13), *(16..21).map(&gpio),
                *(30..33).map { |pin| device.(pin, 3, 0, 1) }]
    assert_equal expected, pi_pin_rows
  end

  # Seeded faults for the uses column, which the packer derives from the manifest's
  # holders, line grants and rescue marks and nothing writes by hand: marking the
  # Bluetooth domain for rescue makes UART0's rows rescue's, and without the line grant
  # UART0 is the system release's own, which rescue uses too.
  def test_the_uses_column_follows_the_holders_grants_and_rescue_marks
    uart0_uses = ->(source) { pi_pin_rows(source).select { |row| row.first >= 30 }.map(&:last).uniq }
    assert_equal [1], uart0_uses.(pi_source)
    rescued = pi_source.sub(/^(domain bt\n(?:  .*\n)*?)  flags none\n/) { "#{Regexp.last_match(1)}  flags rescue\n" }
    refute_equal pi_source, rescued
    assert_equal [2], uart0_uses.(rescued)
    ungranted = pi_source.sub(/^facet line\n(?:  .*\n)*/, '')
    refute_equal pi_source, ungranted
    assert_equal [2], uart0_uses.(ungranted)
  end

  def pi_source = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)

  # The Pi 4 manifest's pins rows from the pin field on, each its pin, owner, controller
  # device, function, alternate, pull, level and uses, with a device row's owner as :device
  # and the controller's device row, the gpio unit's one device, as :controller.
  def pi_pin_rows(source = pi_source)
    bytes = admitted(source, platform: 'raspi4b')
    offset, count = bytes.byteslice(488, 8).unpack('L<L<')
    rows = Array.new(count) { |row| bytes.byteslice(offset + (48 * row) + 16, 32).unpack('L<8') }
    assert_equal 1, rows.map { |row| row[2] }.uniq.size
    rows.map { |pin, owner, _controller, *rest| [pin, owner == 0xffff_ffff ? owner : :device, :controller, *rest] }
  end

  def test_a_firmware_request_of_an_unknown_tag_or_device_is_refused_at_the_packer
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    # A tag outside fw_tag, a path of no device, a PCIe function's empty path, a device that is
    # no bridge, an address with function bits below bit 12, a bus the bridge lists no place
    # on, a word past 32 bits, a name that is no identifier, and words longer and shorter than
    # the tag's one.
    [{ 'tag' => 'get_board_serial' }, { 'device' => '/scb/pcie@7d500001' }, { 'device' => '' },
     { 'device' => '/soc/serial@7e201000' }, { 'arguments' => [0x0010_0001] }, { 'arguments' => [0x0020_0000] },
     { 'arguments' => [1 << 32] }, { 'name' => 'Not an identifier' }, { 'arguments' => [0x0010_0000, 0] },
     { 'arguments' => [] }, { 'arguments' => 0x0010_0000 }].each do |bad|
      assert_firmware_requests_refused(pi) { |rows| rows.map { |row| row.key?('tag') ? row.merge(bad) : row } }
    end
    assert_firmware_requests_refused(pi) { |rows| rows * 2 }
  end

  # The device service asks for a power line's phase by the phase's value in the closed set
  # fw_power_phase (erx_domain_lib:firmware/2), so each phase's row sits at that index among
  # the device's rows, and sets the line's state of that phase (docs/design-bluetooth.md,
  # "The power line").
  def test_each_power_phase_s_row_is_at_the_phase_s_value
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    uart0 = firmware_rows(admitted(pi, platform: 'raspi4b')).select { |row| row[1] == '/soc/serial@7e201000' }
    phases = @codec.schema.types.fetch('fw_power_phase').members
    assert_equal %w[off on], phases.keys.sort
    phases.each do |phase, value|
      assert_equal ["bt_#{phase}", @codec.constant("vc_bt_power_#{phase}")], uart0.fetch(value).values_at(0, 4), phase
    end
  end

  # The power line's rows come only from a power row, so a record row naming SET_GPIO_STATE,
  # here pin 131, GLOBAL_RESET, is refused; so is a power row naming a power line fw_power_line
  # does not declare, a device that is not a UART of the roster or one another row names,
  # or times that are not positive milliseconds.
  def test_a_power_line_comes_only_from_a_declared_power_row_on_a_uart
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    assert_firmware_requests_refused(pi) do |rows|
      rows + [{ 'name' => 'reset', 'device' => '/soc/serial@7e201400', 'tag' => 'set_gpio_state', 'arguments' => [131, 1] }]
    end
    [{ 'power_line' => 'wifi_power' }, { 'device' => '/scb/pcie@7d500000' }, { 'device' => '/soc/serial@7e201001' },
     { 'off_ms' => 0 }, { 'on_ms' => '500' }, { 'tag' => 'set_gpio_state' }].each do |bad|
      assert_firmware_requests_refused(pi) { |rows| rows.map { |row| row.key?('power_line') ? row.merge(bad) : row } }
    end
    error = assert_firmware_requests_refused(pi) { |rows| rows + rows.select { |row| row.key?('power_line') } }
    assert_match(/named by another firmware request/, error.message)
  end

  def test_an_incomplete_or_empty_msi_frame_is_refused_at_the_packer
    [{ 'base' => 0x0802_0000, 'first' => 80 }, { 'base' => 0x0802_0000, 'first' => 80, 'count' => 0 }].each do |frame|
      error = assert_raises(Erx::Manifest::Invalid) { admitted(record: platform_record('qemu-virt').merge('msi_frame' => frame)) }
      assert_equal 'context.platform.msi_frame', error.field
    end
  end

  # The Raspberry Pi 4's development manifest with its framebuffer unit moved from the
  # display domain to the system domain, so a framebuffer row sits on the system domain's page.
  def pi_framebuffer_held_by_system
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    row = "unit framebuffer\n  placement \"framebuffer\"\n  holder @domain.display\n"
    assert_includes pi, row
    pi.sub(row, row.sub('holder @domain.display', 'holder system'))
  end

  # A framebuffer unit the system domain holds: the page keeps the row, its window and
  # /chosen for the root's framebuffer step, and no physical record, since the row's record
  # is the framebuffer record.
  def test_a_framebuffer_row_the_system_domain_holds_keeps_its_window_and_path
    output, status = read(admitted(pi_framebuffer_held_by_system, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "framebuffer #{0x3b40_0000} #{0x4c0_0000} /chosen words 0\n"
  end

  # The shipped Pi manifest gives the framebuffer unit to the display domain, so the system
  # domain's page has no framebuffer row.
  def test_the_shipped_pi_manifest_gives_the_system_domain_no_framebuffer_row
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    refute_match(/^framebuffer /, output)
  end

  # The firmware mailbox's row reaches the root as the RNG200's does: the shipped Pi manifest
  # gives the system domain its unit, with the platform record's path and the window the
  # board's tree states (bus 0x7e00b880 under /soc's ranges, 0x40 bytes), which the root maps
  # for firmware requests once the tree confirms it; given to another domain, the root holds
  # none. It is of no kind, so it makes no device record.
  def test_the_mailbox_row_reaches_the_root_only_from_a_unit_the_system_domain_holds
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    row = "unit mailbox\n  placement \"mailbox\"\n  holder system\n"
    assert_includes pi, row
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "held_mailbox /soc/mailbox@7e00b880 #{0xfe00b880} #{0x40}\n"
    refute_match(/^device .* #{0xfe00b880} /, output)
    output, status = read(admitted(pi.sub(row, row.sub('holder system', 'holder @domain.storage')), platform: 'raspi4b'),
                          stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "held_mailbox none\n"
  end

  # The pin controller's row reaches the root as the mailbox's does: the shipped Pi manifest
  # gives the system domain its unit, with the platform record's path and window (0xfe200000,
  # 180 bytes), where the root sets the on-board pins once at boot; QEMU virt's gives none,
  # so the root writes no pin. The packer gives the unit to no other domain but one of its
  # own (manifest_check_test.rb) (docs/design-header-io.md, "On-board pins"). It is
  # of no kind, so it makes no device record.
  def test_the_pin_controller_row_reaches_the_root_only_from_a_unit_the_system_domain_holds
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    row = "unit gpio\n  placement \"gpio\"\n  holder system\n"
    assert_includes pi, row
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "held_pins /soc/gpio@7e200000 #{0xfe200000} 180\n"
    refute_match(/^device .* #{0xfe200000} /, output)
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "held_pins none\n"
  end

  # The root writes at boot only the rows of the pin controller the system domain holds
  # (liberx/backend/core/boot_manifest.c, erx_boot_pin_rows): UART0's four on the Pi 4, and
  # not a row whose device column names another device, which is not that controller's. The
  # packer's report counts the same rows, which the boot's checkpoint expects
  # (ProductionImage::Run.onboard_pins_points), so a record whose UART0 sits in a unit the
  # manifest does not place gives no row to either.
  def test_the_root_takes_only_the_held_controller_s_rows
    pi = admission(pi_source, platform: 'raspi4b')
    assert_equal 4, pi.report.fetch('boot_pin_rows')
    assert_includes pi_read(pi.bytes), "pin_rows 4\n"

    bytes = pi.bytes.dup
    offset, count = bytes.byteslice(488, 8).unpack('L<L<')
    row = offset + (48 * (0...count).find { |at| bytes.byteslice(offset + (48 * at) + 16, 4).unpack1('L<') == 30 })
    bytes[row + 24, 4] = bytes.byteslice(row + 20, 4) # the device column names UART0, the row's owner
    assert_includes pi_read(bytes), "pin_rows 3\n"

    unplaced = admission(pi_source.sub(/^facet line\n(?:  .*\n)*/, ''), platform: 'raspi4b', record: uart0_unplaced)
    assert_equal 0, unplaced.report.fetch('boot_pin_rows')
    assert_includes pi_read(unplaced.bytes), "pin_rows 0\n"
  end

  # What the driver prints of a Pi 4 manifest's bytes.
  def pi_read(bytes)
    output, status = read(bytes, stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    output
  end

  # The Pi 4's record with UART0 in a unit of its own, which the manifest does not place.
  def uart0_unplaced
    record = platform_record('raspi4b')
    path = '/soc/serial@7e201000'
    uart0 = record.fetch('units').flat_map { |unit| unit.fetch('devices') }.find { |device| device['path'] == path }
    units = record.fetch('units').map { |unit| unit.merge('devices' => unit.fetch('devices').reject { |device| device['path'] == path }) }
    record.merge('units' => [*units, { 'key' => 'uart0', 'devices' => [uart0] }])
  end

  # The RNG200's row reaches the root from the platform record only through a unit the
  # manifest gives the system domain (erx_boot_held_row): the shipped Pi manifest gives it,
  # with the record's path and window; the unit given to another domain, or a board without
  # the row, gives the root none, so it reads no generator. It is of no kind, so it makes no
  # device record.
  def test_the_rng200_row_reaches_the_root_only_from_a_unit_the_system_domain_holds
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    row = "unit rng\n  placement \"rng\"\n  holder system\n"
    assert_includes pi, row
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "held_row /soc/rng@7e104000 #{0xfe104000} 40\n"
    refute_match(/^device .* #{0xfe104000} /, output)
    output, status = read(admitted(pi.sub(row, row.sub('holder system', 'holder @domain.storage')), platform: 'raspi4b'),
                          stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "held_row none\n"
    output, status = read(admitted)
    assert status.success?, output
    assert_includes output, "held_row none\n"
  end

  def dma(role, memory, status, coherent, cpu, bus, last, mac, first, size, *walk)
    arguments = [role, memory, status, coherent, cpu, bus, last, mac, first, size, *walk].map(&:to_s)
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
    window = 'window 167784448 4096 3584 words-erx_record given'
    assert_equal "asks 1 before none after none #{window} net virtio_mmio /virtio_mmio@a003e00 11 3584 512 12 direct 13 65536 0 1 0 " \
                 "0 exact 1 short 0\nline erx: device tree: /virtio_mmio@a003e00: coherent 1 range 0x0 0x0 " \
                 "0xffffffffffffffff mac absent\n",
                 dma('net', 0x10000, 0, 1, 0, 0, all, 0, 0x4800_0000, 0x10000)
    # The Pi model's EMMC2, whose first GiB of CPU addresses it sees from bus address
    # 0xc0000000: memory at CPU 0x10000000 has device address 0xd0000000 and is inside.
    assert_equal "asks 1 before none after none #{window} block virtio_mmio /virtio_mmio@a003e00 11 3584 512 12 direct 13 65536 0 0 0 " \
                 "0 exact 1 short 0\nline erx: device tree: /virtio_mmio@a003e00: coherent 0 range 0x0 0xc0000000 " \
                 "0x3fffffff\n",
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0xd000_0000, 0x10000)
    # Its CPU address as if it were the device's lies below the bus addresses, and memory that
    # runs past the last bus address, 0xffffffff, lies outside too; memory ending there is inside.
    assert_match(/\Aasks 1 before none after outside .* 12 direct 0 0 0 0 0 0 exact.*\nline .*: dma absent outside\n\z/,
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0x1000_0000, 0x10000))
    assert_match(/\Aasks 1 before none after outside /,
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0xffff_8000, 0x10000))
    assert_match(/\Aasks 1 before none after none .* 12 direct 13 65536 0 0 0 0 exact/,
                 dma('block', 0x10000, 0, 0, 0, 0xc000_0000, 0x3fff_ffff, 0, 0xffff_0000, 0x10000))
    # A range whose bus addresses would pass 2^64 - 1, which the reader never gives, admits
    # no memory anywhere rather than wrapping.
    assert_match(/\Aasks 1 before none after outside /,
                 dma('block', 0x10000, 0, 0, 0, all - 0xffff, 0x3fff_ffff, 0, all - 0xffff, 0x10000))
    assert_match(/\Aasks 1 before none after outside .* 12 direct 0 0 0 1 0 0 exact.*\nline .*: dma absent outside\n\z/,
                 dma('block', 0x10000, 0, 1, 0, 0, 0x3fff_ffff, 0, 0x3fff_8000, 0x10000))
    assert_match(/\Aasks 1 before none after none .* 12 direct 13 65536 0 1 0 0 exact.*\nline .*: coherent 1 range 0x0 0x0 0x3fffffff\n\z/,
                 dma('block', 0x10000, 0, 1, 0, 0, 0x3fff_ffff, 0, 0x3fff_0000, 0x10000))
    assert_match(/\Aasks 1 before none after outside /, dma('block', 0x10000, 0, 1, 0x1000, 0x1000, all, 0, 0, 0x10000))
    assert_match(/\Aasks 1 before none after outside /,
                 dma('block', 0x10000, 0, 1, 0, 0, all, 0, 0xffff_ffff_ffff_f000, 0x10000))
    # Without a range the facts' coherence says nothing: the record is not coherent.
    %w[no_node coherence cells malformed ranges].each.with_index(1) do |reason, status|
      walked = reason == 'ranges' ? ' limit none windows 0' : ''
      assert_match(/\Aasks 1 before #{reason} after none .* 12 direct 0 0 0 0 0 0 exact.*\nline .*: dma absent #{reason}#{walked}\n\z/,
                   dma('block', 0x10000, status, 1, 0, 0, all, 0, 0, 0x10000))
    end
  end

# A row whose tree gives no one DMA range shows what the walk ended with (docs/design-device-tree.md,
# "The lines"): the limit, the count, the first four windows with each one's verdict, and how many more;
# or that the walk would carry more than it holds. Statuses and verdicts are the header's order.
def test_a_row_without_a_range_shows_the_windows_the_walk_ended_with
  all = 0xffff_ffff_ffff_ffff
  two = [0x3c00_0000, 0, 0, 0xbfff_ffff, 0, 0x4_0000_0000, 0, 0x4_3fff_ffff, 2]
  assert_match(/\nline erx: device tree: \/virtio_mmio@a003e00: dma absent ranges limit 0x3c000000 windows 2 window 0x0 0x0 0xbfffffff kept window 0x400000000 0x0 0x43fffffff no_ram\n\z/,
               dma('block', 0x10000, 5, 0, 0, 0, all, 0, 0, 0x10000, *two))
  six = (0...6).flat_map { |at| [at << 32, 0x4000_0000 + at, (at << 32) + 0xfff, at % 3] }
  assert_match(/ windows 6 window 0x0 0x40000000 0xfff kept window 0x100000000 0x40000001 0x100000fff above_limit window 0x200000000 0x40000002 0x200000fff no_ram window 0x300000000 0x40000003 0x300000fff kept more 2\n\z/,
               dma('block', 0x10000, 5, 0, 0, 0, all, 0, 0, 0x10000, 0, *six))
  assert_match(/: dma absent ranges limit none windows 6 /, dma('block', 0x10000, 5, 0, 0, 0, all, 0, 0, 0x10000, 0, *six))
  assert_match(/: dma absent ranges limit 0x40000000 windows over\n\z/,
               dma('block', 0x10000, 5, 0, 0, 0, all, 0, 0, 0x10000, 0x4000_0000, 'over'))
  # Another reason prints no windows, whatever the facts hold.
  assert_match(/: dma absent cells\n\z/, dma('block', 0x10000, 3, 0, 0, 0, all, 0, 0, 0x10000, *two))
end

  # Both gives make a device's memory inside the range erx_boot_dma_range builds from its
  # facts, so EMMC2's window keeps its bus offset rather than becoming the identity range a
  # create from CPU addresses would give it.
  def test_the_memory_s_range_keeps_the_tree_s_bus_offset
    range = lambda do |cpu, bus, last|
      output, status = Open3.capture2e(@driver, 'dma_range', *[cpu, bus, last].map(&:to_s))
      assert status.success?, output
      output
    end
    assert_equal "range 0x0 0xc0000000 0x3fffffff\n", range.call(0, 0xc000_0000, 0x3fff_ffff)
    assert_equal "range 0x1000 0x0 0xffffffffffffffff\n", range.call(0x1000, 0, 0xffff_ffff_ffff_ffff)
  end

  # MAC is the tree's address for a network row only, 48 bits with its first byte highest;
  # a network row without DMA memory asks for the address alone, and a block row without
  # DMA memory asks nothing (docs/design-device-tree.md, "What each row asks").
  def test_only_a_network_row_carries_the_tree_s_address
    all = 0xffff_ffff_ffff_ffff
    mac = 0xdca632_0102_03
    assert_match(/ direct 13 65536 0 0 #{mac} 0 exact.*\nline .*: coherent 0 range 0x0 0x0 0xffffffffffffffff mac present\n\z/,
                 dma('net', 0x10000, 0, 0, 0, 0, all, mac, 0x4800_0000, 0x10000))
    assert_match(/ direct 13 65536 0 0 0 0 exact.*\nline .*: coherent 0 range 0x0 0x0 0xffffffffffffffff\n\z/,
                 dma('block', 0x10000, 0, 0, 0, 0, all, mac, 0x4800_0000, 0x10000))
    assert_match(/\Aasks 1 before none after none .* 12 direct 0 0 0 0 #{mac} 0 exact.*\nline erx: device tree: \/virtio_mmio@a003e00: mac present\n\z/,
                 dma('net', 0, 0, 1, 0, 0, all, mac, 0, 0))
    assert_match(/\Aasks 0 before none after none .* 12 direct 0 0 0 0 0 0 exact/, dma('block', 0, 0, 1, 0, 0, all, mac, 0, 0))
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
    assert_includes output, "console_uart pl011 150994944 4096 33 direct 24000000\n"
    assert_includes output, "console_words-erx_record console pl011 150994944 4096 33 direct 24000000 exact 1 short 0\n"
    assert_match(/^device hostlink pl011 \d+ \d+ 40 direct .*words-erx_record device hostlink pl011 \/pl011@9040000 \d+ \d+ 40 direct \d+ \d+ 0 0 exact 1/, output)
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
    output, status = read(admitted(pi, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_match(/^console_uart mini_uart #{0xfe215040} 64 125 shared \d+\n/, output)
    assert_match(/^console_words-erx_record console mini_uart #{0xfe215040} 64 125 shared \d+ exact 1 short 0\n/, output)
    assert_match(/^device hostlink pl011 \d+ \d+ 153 shared .*words-erx_record device hostlink pl011 \/\S+ \d+ \d+ 153 shared \d+ \d+ 0 0 exact 1/,
                 output)
  end

  # The console's record names the CMSIS-SVD peripheral of its entry's compatible string,
  # from the root's table of UART kinds (docs/design-fiasco.md, "The console"); an entry
  # of a compatible string no row names gets no record, so the console refuses the boot with
  # its reason rather than start a driver for a UART it does not know. The check refuses such
  # a manifest (test_a_console_of_no_uart_kind_is_refused_at_the_check), so this one is
  # admitted against a table with one more row than the root's.
  def test_a_console_of_no_uart_kind_gets_no_record
    record = platform_record('qemu-virt')
    console = record.fetch('units').flat_map { |unit| unit.fetch('devices') }
                    .find { |device| device.fetch('path') == '/pl011@9000000' }
    console.merge!('compatible' => 'ns16550a', 'clock' => 0)
    planted = ManifestContextFixture.device_kinds + [{ 'role' => 'uart', 'compatible' => 'ns16550a', 'role_word' => 'console',
                                                       'peripheral' => 'ns16550', 'clocked' => false }]
    output, status = read(admitted(record: record, device_kinds: planted))
    assert status.success?, output
    assert_includes output, "console_uart none 0 0 0 direct 0\n"
    assert_includes output, "console_wordsexact 0 short 0\n"
  end

  # Line 0 is no line (docs/design-abi.md, "Devices and partition windows"): the Pi's
  # framebuffer row, here on the system domain's page (pi_framebuffer_held_by_system), and
  # its RNG200's carry it beside the console, whose line stays its own unit's; a driven
  # device given line 0, the mini UART, would bind no line, and the check refuses it.
  def test_line_zero_is_no_line
    output, status = read(admitted(pi_framebuffer_held_by_system, platform: 'raspi4b'), stdout_path: '/soc/serial@7e215040')
    assert status.success?, output
    assert_includes output, "framebuffer #{0x3b40_0000} "
    assert_match(/^console_uart mini_uart #{0xfe215040} 64 125 shared \d+\n/, output)
    record = platform_record('raspi4b')
    record.fetch('units').find { |unit| unit.fetch('key') == 'console-uart' }.fetch('devices')
          .find { |device| device.fetch('path') == '/soc/serial@7e215040' }['line'] = 0
    error = assert_raises(Erx::Manifest::Invalid) { admitted(pi_framebuffer_held_by_system, platform: 'raspi4b', record: record) }
    assert_includes error.message, 'names no interrupt line'
  end

  # window: the row's window, by default every page but the last.
  def framebuffer(status, base, length, width, height, stride, format, window: [0, 0xffff_ffff_ffff_f000])
    arguments = [status, base, length, width, height, stride, format, *window].map(&:to_s)
    output, status_ = Open3.capture2e(@driver, 'framebuffer', *arguments)
    assert status_.success?, output
    output
  end

  # The root's framebuffer step (docs/design-device-tree.md, "Facts into records" and "The
  # lines"): the pages a placed framebuffer lies in, its offset in the first, the record over
  # them, and the line of fixed words and the facts' numbers. Statuses are
  # erx_dt_fb_status_t's order: 0 ok, 1 none, 2 ambiguous, 3 malformed, 4 unsupported,
  # 5 outside.
  def test_a_placed_framebuffer_gives_its_pages_its_record_and_its_line
    assert_equal "pages #{0x3e00_0000} #{0x7e_a000} 1024 words-erx_record framebuffer 11 1024 #{0x7e_9000} 1920 1080 7680 " \
                 "a8r8g8b8 exact 1 short 0\nline erx: device tree: /chosen: framebuffer 1920x1080 7680 a8r8g8b8\n",
                 framebuffer(0, 0x3e00_0400, 0x7e_9000, 1920, 1080, 7680, 'a8r8g8b8')
    # An empty framebuffer, or one ending past the top of the address space, has no pages.
    assert_match(/\Apages none /, framebuffer(0, 0x3e00_0000, 0, 1920, 1080, 7680, 'a8r8g8b8'))
    assert_match(/\Apages none /, framebuffer(0, 0xffff_ffff_ffff_f000, 0x2000, 1, 1, 4, 'a8r8g8b8'))
  end

  # Placed is one decision (erx_boot_framebuffer_place): facts of ERX_DT_FB_OK with a named
  # format whose pages lie inside the row's window. Facts nothing wrote are all zero, which
  # reads as ERX_DT_FB_OK, and are not placed; nor is a framebuffer without a format's name,
  # or one whose pages leave the window, even by the page its offset adds.
  def test_only_named_facts_whose_pages_lie_in_the_window_are_placed
    assert_match(/\Apages none /, framebuffer(0, 0, 0, 0, 0, 0, 'a8r8g8b8'))
    assert_match(/\Apages none /, framebuffer(0, 0x3e00_0000, 0x7e_9000, 1920, 1080, 7680, '-'))
    window = [0x3e00_0000, 0x7e_9000]
    assert_match(/\Apages #{0x3e00_0000} #{0x7e_9000} 0 /,
                 framebuffer(0, 0x3e00_0000, 0x7e_9000, 1920, 1080, 7680, 'a8r8g8b8', window: window))
    assert_match(/\Apages none /, framebuffer(0, 0x3e00_0400, 0x7e_9000, 1920, 1080, 7680, 'a8r8g8b8', window: window))
    assert_match(/\Apages none /, framebuffer(0, 0x3dff_f000, 0x1000, 1, 1, 4, 'a8r8g8b8', window: window))
    assert_match(/\Apages none /, framebuffer(0, 0xffff_ffff_ffff_f000, 0x1000, 1, 1, 4, 'a8r8g8b8'))
  end

  # A framebuffer the reader did not place has no pages and no record, only its line.
  def test_a_framebuffer_the_reader_did_not_place_has_only_its_line
    %w[none ambiguous malformed unsupported].each.with_index(1) do |reason, status|
      assert_equal "pages none wordsexact 0 short 0\nline erx: device tree: /chosen: framebuffer absent #{reason}\n",
                   framebuffer(status, 0x3e00_0000, 0x7e_9000, 1920, 1080, 7680, 'a8r8g8b8')
    end
    assert_equal "pages none wordsexact 0 short 0\nline erx: device tree: /chosen: framebuffer absent outside " \
                 "0x3e000000 0x7e9000\n", framebuffer(5, 0x3e00_0000, 0x7e_9000, 0, 0, 0, '-')
  end

  # FORMAT is a name of the reader's table, the longest eleven bytes, which the record's room
  # holds (ERX_BOOT_FORMAT_WORD_MAX); a longer word gives no record, and no name neither record nor line.
  def test_the_record_s_format_is_a_word_of_its_bounded_room
    assert_match(/ 7680 a2r10g10b10 exact 1 short 0\nline .*: framebuffer 1920x1080 7680 a2r10g10b10\n\z/,
                 framebuffer(0, 0x3e00_0000, 0x7e_9000, 1920, 1080, 7680, 'a2r10g10b10'))
    assert_match(/ wordsexact 0 short 0\n/, framebuffer(0, 0x3e00_0000, 0x7e_9000, 1920, 1080, 7680, 'a2r10g10b10x'))
    assert_match(/ wordsexact 0 short 0\nline \z/, framebuffer(0, 0x3e00_0000, 0x7e_9000, 1920, 1080, 7680, '-'))
    assert_match(/ 4294967295 4294967295 4294967295 x2r10g10b10 exact 1 short 0\n/,
                 framebuffer(0, 0x1000, 0xffff_ffff_0000, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff, 'x2r10g10b10'))
  end
end
