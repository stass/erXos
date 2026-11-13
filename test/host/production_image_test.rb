# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'minitest/autorun'
require 'open3'
require 'pathname'
require 'rbconfig'
require_relative '../../tools/lib/erx/oracle_qemu'
require_relative '../../tools/lib/erx/medium_boot'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/net_device'

# The production image's host-side rules. Its boot is the QEMU gate's production_image suite.
class ProductionImageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  DEVELOPMENT = Erx::ProductionImage::Machine.development(PLATFORM)
  TREE = <<~DTS
    /dts-v1/;

    / {
    \tmemory@40000000 {
    \t\treg = <0x00 0x40000000 0x00 0x10000000>;
    \t\tdevice_type = "memory";
    \t};

    \tpl011@9000000 {
    \t\tclock-names = "uartclk", "apb_pclk";
    \t\tclocks = <0x8000 0x8000>;
    \t\tcompatible = "arm,pl011", "arm,primecell";
    \t\treg = <0x00 0x9000000 0x00 0x1000>;
    \t\tinterrupts = <0x00 0x01 0x04>;
    \t};

    \tvirtio_mmio@a003e00 {
    \t\tcompatible = "virtio,mmio";
    \t\treg = <0x00 0xa003e00 0x00 0x200>;
    \t\tinterrupts = <0x00 0x2f 0x01>;
    \t};

    \tapb-pclk {
    \t\tphandle = <0x8000>;
    \t\tclock-frequency = <0x16e3600>;
    \t\tcompatible = "fixed-clock";
    \t};
    };
  DTS

  UART_WINDOW = { base: 0x9000000, size: 0x1000, line: 33 }.freeze
  BLOCK_WINDOW = { base: 0xa003e00, size: 0x200, line: 79 }.freeze

  # A record of one device on QEMU virt's RAM; a PL011 has virt's 24 MHz clock unless the
  # window says otherwise.
  def platform(path:, compatible: 'arm,pl011', **window)
    clock = compatible == 'arm,pl011' ? { 'clock' => 24_000_000 } : {}
    device = { 'selector' => 'dt', 'path' => path, 'compatible' => compatible, **clock, **window.transform_keys(&:to_s) }
    { 'ram_first' => 0x4000_0000, 'units' => [{ 'devices' => [device] }] }
  end

  def test_every_import_the_root_links_is_registered
    linked = Erx::NativeRoot::SERVICE.filter_map do |source|
      Pathname(source).ascend.map(&:to_s).find { |directory| File.file?(File.join(ROOT, directory, 'ORIGIN.md')) }
    end
    assert_empty linked.uniq - Erx::ProductionImage::IMPORTS.keys
  end

  # The default runtimes read the machine's platform, so a machine of another type is refused
  # with a stated reason before they do.
  def test_an_image_is_built_for_a_machine
    fiasco = Object.new
    error = assert_raises(Erx::Error) do
      Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '', machine: PLATFORM, fiasco: fiasco)
    end
    assert_match(/ProductionImage::Machine/, error.message)
  end

  # The runtimes are linked for the builder's board, so a medium or test image for a machine
  # of another board is refused before anything is built.
  def test_an_image_builder_stays_on_its_board
    other = Erx::Platform.new(name: 'other-board', record: PLATFORM.record.merge('name' => 'other-board'))
    machine = DEVELOPMENT.with(platform: other)
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '', machine: DEVELOPMENT, fiasco: Object.new,
                                     runtime: nil, jit_runtime: nil)
    error = assert_raises(Erx::Error) { image.build_medium(directory: '/nonexistent', machine: machine, manifest_source: '') }
    assert_equal 'a qemu-virt image builder cannot build for other-board', error.message
    assert_raises(Erx::Error) do
      image.build_test_image(directory: '/nonexistent', added: nil, machine: machine, manifest_source: '')
    end
  end

  # libbeam.a holds littlefs's objects (lfs.o and lfs_util.o, in the emulator's OS_OBJS), so
  # its attribution names littlefs's license beside OTP's; compiler-rt's builtins carry LLVM's
  # license, and nothing linked is GPL; every notice named is a tree file.
  def test_emulator_archive_carries_the_littlefs_notice
    fiasco = Struct.new(:boot_core_archive) { def user_library(name) = "/fiasco/#{name}" }.new('/fiasco/boot_cores.a')
    erts = Erx::NativeRuntime::Built.new(otp_archives: ['/otp/erl_main.o', '/otp/libbeam.a'], libc: '/musl/libc.a',
                                         builtins: '/crt/libclang_rt.builtins.a', otp: '/otp')
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '', machine: DEVELOPMENT, fiasco: fiasco,
                                     runtime: nil)
    archives = image.send(:archives, erts).to_h { |archive| [File.basename(archive.path), archive] }
    assert_equal 'Apache-2.0 AND BSD-3-Clause', archives.fetch('libbeam.a').license
    assert_equal %w[otp/LICENSE.txt littlefs/LICENSE.md], archives.fetch('libbeam.a').notices
    assert_equal %w[otp/LICENSE.txt], archives.fetch('erl_main.o').notices
    builtins = archives.fetch('libclang_rt.builtins.a')
    assert_equal ['Apache-2.0 WITH LLVM-exception', 'permanent'], [builtins.license, builtins.status]
    assert_equal 'compiler-rt/LICENSE.TXT', builtins.notices.first[%r{compiler-rt/LICENSE\.TXT\z}]
    refute archives.values.any? { |archive| archive.license.include?('GPL') }, 'no archive the image links is GPL'
    makefile = File.read(File.join(ROOT, 'otp/erts/emulator/Makefile.in'))
    assert_match %r{^LFS_DIR = \$\(ERX_TREE\)/littlefs$}, makefile
    archives.values.flat_map(&:notices).each { |notice| assert File.file?(File.join(ROOT, notice)), notice }
  end

  # The dedication in each ChaCha20 file's header is the only license statement it holds, and
  # attribution keeps that header as the file's notice. erXos's changes add BSD-2-Clause, whose
  # text is erXos's own LICENSE. No source file stands in as a notice document.
  def test_chacha20_files_carry_their_own_dedication
    directory = 'kernel/crypto/chacha20'
    changes = Erx::Origin.new(root: File.join(ROOT, directory)).inventory.fetch('changes')
    profile = Erx::ImportNotices.parse(File.binread(File.join(ROOT, 'config/provenance/import-notices.json')))
    license = { 'path' => 'LICENSE', 'sha256' => Digest::SHA256.file(File.join(ROOT, 'LICENSE')).hexdigest }
    %w[chacha.c chacha.h].each do |name|
      source = File.join(directory, name)
      bytes = File.binread(File.join(ROOT, source))
      digest = Digest::SHA256.hexdigest(bytes)
      change = changes.fetch(name)
      assert_equal bytes[/SPDX-License-Identifier: (.*)$/, 1], change.fetch('license')
      assert_equal digest, change.fetch('sha256')
      assert_match(/D\. J\. Bernstein\nPublic domain\./, bytes[/\A.*?^#/m])
      grants = Erx::LicenseExpression.select(change.fetch('license'), allow_restricted: false).fetch('grants')
      assert_equal [license], Erx::ImportNotices.select(profile, source: source, grants: grants)
    end
  end

  def test_a_device_the_tree_holds_has_no_problem
    assert_empty Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000', **UART_WINDOW), TREE)
    assert_empty Erx::ProductionImage.device_path_problems(platform(path: '/virtio_mmio@a003e00', compatible: 'virtio,mmio', **BLOCK_WINDOW), TREE)
  end

  def test_a_path_the_tree_lacks_is_named
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9040000', **UART_WINDOW), TREE)
    assert_equal ['/pl011@9040000: not in the device tree'], problems
  end

  def test_a_node_of_another_kind_is_named
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/virtio_mmio@a003e00', **BLOCK_WINDOW), TREE)
    assert_match(/compatible .* does not name arm,pl011/, problems.fetch(0))
  end

  # The line counts the interrupt's type: 33 is shared line 1, 17 would be private line 1.
  def test_a_window_the_tree_does_not_give_is_named
    [UART_WINDOW.merge(base: 0x9000400), UART_WINDOW.merge(size: 0x200), UART_WINDOW.merge(line: 1),
     UART_WINDOW.merge(line: 17)].each do |window|
      problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000', **window), TREE)
      assert_match(/base, size or line .* differ/, problems.fetch(0), window.inspect)
    end
  end

  def test_a_node_without_a_readable_window_is_named
    tree = TREE.sub("\t\tinterrupts = <0x00 0x01 0x04>;\n", "\t\tinterrupts = <0x02 0x01 0x04>;\n")
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000', **UART_WINDOW), tree)
    assert_match(/unreadable reg or interrupts/, problems.fetch(0))
  end

  # erx_pl011 divides the baud rate from the record's clock, so a clock other than the
  # fixed-clock the node's first clocks entry names, or none, is named.
  def test_a_pl011_clock_the_tree_does_not_give_is_named
    [{ clock: 48_000_000 }, { clock: nil }].each do |clock|
      problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000', **UART_WINDOW, **clock), TREE)
      assert_equal ["/pl011@9000000: clock #{clock.fetch(:clock).inspect} differs from the tree's 24000000"], problems
    end
  end

  def test_a_pl011_whose_clock_is_no_fixed_clock_is_named
    [TREE.sub("\t\tclocks = <0x8000 0x8000>;\n", ''), TREE.sub('"fixed-clock"', '"other-clock"'),
     TREE.sub("\t\tphandle = <0x8000>;\n", "\t\tphandle = <0x8001>;\n")].each do |tree|
      refute_equal TREE, tree
      problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000', **UART_WINDOW), tree)
      assert_equal ["/pl011@9000000: clock 24000000 differs from the tree's unreadable fixed-clock"], problems
    end
  end

  def test_a_row_without_its_window_is_named
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000'), TREE)
    assert_match(/base, size or line .* differ/, problems.fetch(0))
  end

  # A device tree path's unit address is its node's first reg address, so the checked-in
  # record's base must agree with its own path without QEMU to ask.
  def test_each_recorded_base_is_its_paths_unit_address
    record = PLATFORM.record
    windows = record.fetch('units').flat_map { |unit| unit.fetch('devices') }.select { |device| device.fetch('selector') == 'dt' }
    refute_empty windows
    windows.each { |device| assert_equal device.fetch('path')[/@(\h+)\z/, 1].to_i(16), device.fetch('base'), device.fetch('path') }
  end

  # The production path must not reach the structural recipe under test/fixtures, directly
  # or through a library it loads.
  def test_the_production_path_loads_no_test_fixture
    script = "require #{File.join(ROOT, 'tools/lib/erx/production_image').inspect}; puts $LOADED_FEATURES"
    output, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, output
    assert_includes output, 'production_image.rb'
    assert_empty output.lines.grep(%r{/test/fixtures/})
  end

  def test_the_refusal_transcript_ends_at_the_roots_diagnostic
    point = Erx::ProductionImage::Run.refusal_checkpoints.last
    assert_match point.fetch(:pattern), 'erx: root task refused the boot: manifest: root_memory is more than this machine gives the root'
  end

  # The seeded boot: the console's node is renamed, stdout-path names it through an alias
  # with options, and the refusal it expects names both paths.
  def test_the_seeded_tree_renames_the_console_and_names_it_through_an_alias
    dts = "/dts-v1/;\n\n/ {\n\tmodel = \"virt\";\n\n\tpl011@9000000 {\n\t\treg = <0x00 0x9000000 0x00 0x1000>;\n\t};\n\n" \
          "\taliases {\n\t\tserial0 = \"/pl011@9000000\";\n\t};\n\n\tchosen {\n\t\tstdout-path = \"/pl011@9000000\";\n\t};\n};\n"
    seeded = Erx::ProductionImage.seed_stdout_path(dts, node: '/pl011@9000000', renamed: '/uart@9000000', alias_name: 'serial0')
    refute_includes seeded, 'pl011@9000000'
    assert_includes seeded, "\tuart@9000000 {\n"
    assert_includes seeded, "\t\tstdout-path = \"serial0:115200n8\";\n"
    assert seeded.end_with?("/ {\n\taliases {\n\t\tserial0 = \"/uart@9000000\";\n\t};\n};\n")
    assert_raises(Erx::Error) { Erx::ProductionImage.seed_stdout_path("/ {\n};\n", node: '/a', renamed: '/b', alias_name: 'c') }
    point = Erx::ProductionImage::Run.stdout_path_refusal_checkpoints(machine: DEVELOPMENT).last
    line = "erx: root task refused the boot: manifest: the console /pl011@9000000 is not the node /chosen/stdout-path names, /uart@9000000\r\n"
    assert_match point.fetch(:pattern), line
    refute_match point.fetch(:pattern), line.sub('/uart@9000000', '(none)')
  end

  # The non-coherent boot's tree (docs/design-device-tree.md, "The live tree on QEMU"):
  # the named node and the root lose their marks, another node and a child keep theirs,
  # and a node without the mark refuses the seed rather than boot a stock tree as the
  # seeded one.
  def test_the_noncoherent_seed_and_the_checks_it_is_booted_with
    dts = "/ {\n\tdma-coherent;\n\tvirtio_mmio@a002c00 {\n\t\tdma-coherent;\n\t\treg = <0x00 0xa002c00 0x00 0x200>;\n\t};\n\n" \
          "\tvirtio_mmio@a002e00 {\n\t\tchild {\n\t\t\tdma-coherent;\n\t\t};\n\t\tdma-coherent;\n" \
          "\t\treg = <0x00 0xa002e00 0x00 0x200>;\n\t};\n};\n"
    seeded = Erx::ProductionImage.seed_noncoherent(dts, node: '/virtio_mmio@a002e00')
    assert_equal dts.sub("\t\t};\n\t\tdma-coherent;\n", "\t\t};\n").sub("/ {\n\tdma-coherent;\n", "/ {\n"), seeded
    assert_raises(Erx::Error) { Erx::ProductionImage.seed_noncoherent(seeded, node: '/virtio_mmio@a002e00') }
    assert_raises(Erx::Error) { Erx::ProductionImage.seed_noncoherent(dts, node: '/virtio_mmio@a003e00') }
    node = Erx::NetDevice.nic_node(PLATFORM)
    assert_equal '/virtio_mmio@a002e00', node
    line = "erx: device tree: #{node}: coherent 0 range 0x0 0x0 0xffffffffffffffff mac absent\r\n"
    assert_match Erx::NetDevice.tree_checkpoint(node, coherent: false).fetch(:pattern), line
    refute_match Erx::NetDevice.tree_checkpoint(node, coherent: true).fetch(:pattern), line
  end

  FakeBuilt = Struct.new(:build_id, :index_hash, :flags, :test_code, keyword_init: true)

  def checkpoint_verifier(name, built: FakeBuilt.new(build_id: 'aa', index_hash: 'bb', flags: 1, test_code: false), **options)
    points = Erx::ProductionImage::Run.checkpoints(built, root: ROOT, watchdog: '1,30,600', cpus: 4,
                                                   **{ manifest_source: PLATFORM.manifest_source(ROOT),
                                                       memory_mib: DEVELOPMENT.memory_mib }.merge(options))
    points.find { |point| point.fetch(:name) == name }.fetch(:verify)
  end

  # A production boot is of an image that carries no test code, and the kernel must report
  # the archive's own identity and flags, so a test image's mark would show.
  def test_a_production_boot_is_of_an_image_without_test_code
    verify = checkpoint_verifier('image-identity')
    verify.call("erx: boot image build aa index bb flags 0x1 archive 0x40200000+0x1000 bootargs 0\r\n")
    assert_raises(Erx::Error) { verify.call("erx: boot image build aa index bb flags 0x5 archive 0x40200000+0x1000 bootargs 0\r\n") }
    assert_raises(Erx::Error) { verify.call("erx: boot image build ab index bb flags 0x1 archive 0x40200000+0x1000 bootargs 0\r\n") }
    test_image = FakeBuilt.new(build_id: 'aa', index_hash: 'bb', flags: 5, test_code: true)
    error = assert_raises(Erx::Error) { checkpoint_verifier('image-identity', built: test_image) }
    assert_match(/refuses a test image/, error.message)
  end

  # The boot ends at the command shell's banner. The person at the console types erl
  # before the driver starts and the sum at the Erlang shell's banner; at rest, erl is
  # typed at the command shell's banner and the busy loop at the Erlang shell's.
  def test_the_console_boots_reach_the_erlang_shell_through_the_command_shell
    run = Erx::ProductionImage::Run
    rc = "rc: the command shell; erl starts the Erlang shell\r\n"
    eshell = "Eshell V16.0 (type help(). for help)\r\n"
    shells = ->(points) { points.drop_while { |point| point.fetch(:name) != 'release-shell' }.first(2) }
    assert_match run::RELEASE_SHELL.fetch(:pattern), rc
    refute_match run::RELEASE_SHELL.fetch(:pattern), "rc: the command shell; exit ends it\r\n"

    console = run.console_checkpoints(machine: DEVELOPMENT)
    assert_equal "erl\r", console.find { |point| point.fetch(:name) == 'development-warning' }.fetch(:type)
    release, shell = shells.call(console)
    assert_equal [%w[release-shell shell], nil, "1+1.\r"], [[release, shell].map { |point| point.fetch(:name) }, release[:type], shell[:type]]
    assert_match release.fetch(:pattern), rc
    assert_match shell.fetch(:pattern), eshell
    menu, left = %w[ctrl-g-menu menu-left].map { |name| console.find { |point| point.fetch(:name) == name } }
    assert_equal [run::ESC, "1+2\x7f3.\r"], [menu, left].map { |point| point.fetch(:type) }
    assert_match menu.fetch(:pattern), "erx_console: Ctrl-G menu\r\n"
    assert_match left.fetch(:pattern), "Esc returns. \e\\\e[0m\r\n"
    # A log line is written whole between whatever else is written, so one can land after
    # the menu's last line, which has no newline, and before the close (docs/design-live.md,
    # "Log lines and program output"); the close then starts a line of its own.
    assert_match left.fetch(:pattern), "\e\\\e[0m\r\n"
    refute_match left.fetch(:pattern), "Esc returns. #6 0.689895 debug space 1: erx_virtio_net: the network device is not driven\r\n"

    release, erlang = shells.call(run.idle_checkpoints(cpus: 1, root: ROOT, machine: DEVELOPMENT))
    assert_equal ["erl\r", run::BUSY_EXPRESSION], [release, erlang].map { |point| point.fetch(:type) }
    assert_match release.fetch(:pattern), "erx: root task: group: parked 2 of 2#{rc}"
    assert_match erlang.fetch(:pattern), "1> #{eshell}"
  end

  # The kernel records boot types erl at the command shell, each collector in turn at the
  # Erlang shell, and the summary last. No selector takes the echo of its own typed line,
  # nor the shell's redraw of it, both lines of a real transcript, and the summary's line
  # must carry the stopgap table's statuses exactly: each mutant line, one status off, is
  # refused.
  def test_the_kernel_records_boot_reads_each_collector_and_holds_the_summary_to_the_table
    run = Erx::ProductionImage::Run
    points = run.kernel_record_checkpoints(cpus: 4, machine: DEVELOPMENT)
    typed = points.filter_map { |point| point[:type] }.drop_while { |line| line != "erl\r" }
    calls = %w[machine cpus group budget threads].map { |call| %(io:format("~w~n",[erx_kernel_records:#{call}()]).\r) }
    assert_equal ["erl\r", *calls, run::KERNEL_RECORD_SUMMARY], typed
    selectors = points.select { |point| point.fetch(:name).start_with?('kernel-record-') }
    assert_equal %w[machine cpus group budget threads summary], selectors.map { |point| point.fetch(:name).delete_prefix('kernel-record-') }
    selectors.zip(typed.drop(1)).each_with_index do |(point, line), at|
      echo = "#{at + 1}> #{line.chomp("\r")}\r\n"
      refute_match point.fetch(:pattern), echo, point.fetch(:name)
      refute_match point.fetch(:pattern), "\e[A\e[J#{echo}", point.fetch(:name)
      refute_match point.fetch(:pattern), "ok\r\n", point.fetch(:name)
    end
    machine = '#{id => 0,path => [],kind => machine,schema => 1,attrs => #{cpus_online => {kernel,{ok,4}}},children => [cpus]}'
    assert_match selectors.first.fetch(:pattern), "#{machine}\r\n"
    assert_match selectors[1].fetch(:pattern), "{ok,[#{machine.sub('kind => machine', 'kind => cpu')}]}\r\n"

    verify = points.last.fetch(:verify)
    group = '[{parked,{kernel,{ok,4}}},{ready,{kernel,{ok,0}}}]'
    machine_summary = '[{boot_value,{kernel,{ok,normal}}},{build,{kernel,{ok,<<48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102>>}}},' \
                      '{cpus_online,{kernel,{ok,4}}},{memory_free,{{stopgap,liberx_pool},{partial,8192}}},' \
                      '{memory_total,{{stopgap,liberx_pool},{partial,65536}}},{uptime,{kernel,{ok,1234}}}]'
    good = "{object_info,#{machine_summary},{ok,4,[]},#{group}," \
           "[{used,{{stopgap,liberx_pool},{partial,812}}}],{ok,9,[]}}\r\n"
    verify.call(good)
    verify.call("3> #{good}")
    { 'cpus_online unsupported' => good.sub('{cpus_online,{kernel,{ok,4}}},', ''),
      'build unsupported' => good.sub('{build,{kernel,{ok,<<48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102>>}}},', ''),
      'a build not in hex' => good.sub('48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102', '48,49,50,51,52,53,54,55,56,57,65,66,67,68,69,70'),
      'boot_value unsupported' => good.sub('{boot_value,{kernel,{ok,normal}}},', ''),
      'boot_value a number' => good.sub('{ok,normal}', '{ok,2}'),
      'uptime unsupported' => good.sub(',{uptime,{kernel,{ok,1234}}}', ''),
      'memory reported as the kernel' => good.sub('{memory_total,{{stopgap,liberx_pool},{partial,65536}}}',
                                                  '{memory_total,{kernel,{ok,65536}}}'),
      'free memory of zero' => good.sub('{partial,8192}', '{partial,0}'),
      'another CPU count' => good.sub('{cpus_online,{kernel,{ok,4}}}', '{cpus_online,{kernel,{ok,1}}}'),
      'another machine attribute reported' => good.sub('{cpus_online,', '{development,{kernel,{ok,true}}},{cpus_online,'),
      'a CPU listing cut short' => good.sub('{ok,4,[]}', '{partial,4,[]}'),
      'a CPU listing of another length' => good.sub('{ok,4,[]}', '{ok,3,[]}'),
      'a CPU attribute reported' => good.sub('{ok,4,[]}', '{ok,4,[{idle_time,{kernel,{ok,7}}}]}'),
      'used reported as the kernel' => good.sub('{{stopgap,liberx_pool},{partial,812}}', '{kernel,{ok,812}}'),
      'used under another stopgap' => good.sub('liberx_pool', 'liberx_umtx'),
      'used of zero' => good.sub('{partial,812}', '{partial,0}'),
      'used unsupported' => good.sub('[{used,{{stopgap,liberx_pool},{partial,812}}}]', '[]'),
      'a cpuset no set configured' => good.sub('[{parked,', '[{cpuset,{kernel,{ok,15}}},{parked,'),
      'a group attribute missing' => good.sub(',{ready,{kernel,{ok,0}}}', ''),
      'no threads listed' => good.sub('{ok,9,[]}', '{ok,0,[]}'),
      'a thread listing cut short' => good.sub('{ok,9,[]}', '{partial,9,[]}'),
      'a thread state reported' => good.sub('{ok,9,[]}', '{ok,9,[{state,{kernel,{ok,running}}}]}'),
      'bytes after the summary' => good.sub("}\r\n", "}x\r\n") }.each do |what, line|
      refute_equal good, line, what
      assert_raises(Erx::Error, what) { verify.call(line) }
    end
  end

  # A test image's kernel says so right after the development warning; a production boot's
  # transcript has no such line.
  def test_a_test_image_transcript_carries_its_mark_after_the_development_warning
    names = ->(points) { points.map { |point| point.fetch(:name) } }
    production = Erx::Qemu.boot_transcript(memory_mib: 512)
    test_image = Erx::Qemu.boot_transcript(memory_mib: 512, test_image: true)
    refute_includes names.call(production), Erx::Qemu::TEST_IMAGE_BANNER.fetch(:name)
    assert_equal names.call(production).index('development-warning') + 1,
                 names.call(test_image).index(Erx::Qemu::TEST_IMAGE_BANNER.fetch(:name))
    assert_match Erx::Qemu::TEST_IMAGE_BANNER.fetch(:pattern), "test image: carries test code\r\n"
  end

  # The production entry point takes no additions: only the test entry point adds test
  # code, and the source check holds its callers (Checks::TEST_IMAGE_BUILDERS).
  def test_the_production_build_takes_no_additions
    production = Erx::ProductionImage.instance_method(:build).parameters
    refute_includes production.map(&:last), :added
    assert_equal [%i[keyreq directory], %i[keyreq added], %i[key machine], %i[key domains], %i[key manifest_source]],
                 Erx::ProductionImage.instance_method(:build_test_image).parameters
  end

  # A test-only application (ErlangApps::TEST_ONLY) boots only from a test script, which
  # domain_boot makes only when asked, never from the release scripts table, and only
  # an image with the test-code mark carries a test script; no release lists one.
  def test_only_a_test_image_boots_a_test_only_application
    applications = [*Erx::ReleaseFiles::DOMAIN_BASE, *Erx::ErlangApps::TEST_ONLY]
    error = assert_raises(Erx::Error) { Erx::ReleaseFiles.domain_boot('echo', applications: applications) }
    assert_match(/test-only application: .*\berx_echo_test\b/, error.message)
    script = Erx::ReleaseFiles.domain_boot('echo', applications: applications, test: true)
    assert_equal applications.sort, script.applications.sort
    error = assert_raises(Erx::Error) { Erx::ProductionImage.check_test_scripts([script], test_code: false) }
    assert_match(/only a test image carries a test domain boot script: echo/, error.message)
    Erx::ProductionImage.check_test_scripts([script], test_code: true)
    Erx::ProductionImage.check_test_scripts([Erx::ProductionImage.domain_boot('session')], test_code: false)
    assert_empty Erx::ReleaseFiles::APPLICATIONS & Erx::ErlangApps::TEST_ONLY
    refute(Erx::ReleaseFiles::RELEASE_SCRIPTS.keys.any? { |name| Erx::ProductionImage.domain_boot(name).test })
  end

  # A release name the release scripts table does not hold is refused, not booted as the
  # base, so a misspelt `release @artifact.NAME` fails the build.
  def test_a_release_the_table_does_not_hold_is_refused
    error = assert_raises(Erx::ProductionImage::UnknownRelease) { Erx::ProductionImage.domain_boot('sesion') }
    assert_match(/no domain boot script is named "sesion"/, error.message)
    assert_equal Erx::ReleaseFiles::DOMAIN_BASE, Erx::ProductionImage.domain_boot('erts').applications
  end

  # A test image's own scripts stand in for the table's: a manifest row may name a script
  # only the harness gives, and the table's scripts fill in every other name.
  def test_a_test_image_carries_its_own_scripts_in_place_of_the_tables
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '', machine: DEVELOPMENT, fiasco: Object.new,
                                     runtime: nil, jit_runtime: nil)
    row = "domain e\n  principal @principal.system\n  limits @limits.native\n  kind service\n  flags none\n" \
          "  runtime @artifact.emu\n  release @artifact.echo\n  restarts 0\n  restart_period_s 0\n"
    source = Erx::ProductionImage.without_sessions(PLATFORM.manifest_source(ROOT)) + row
    assert_raises(Erx::ProductionImage::UnknownRelease) { image.send(:domain_boots, source) }
    echo = Erx::ReleaseFiles.domain_boot('echo', applications: [*Erx::ReleaseFiles::DOMAIN_BASE, 'erx_echo_test'], test: true)
    assert_equal [echo, *%w[display network storage web].map { |name| Erx::ProductionImage.domain_boot(name) }],
                 image.send(:domain_boots, source, given: [echo])
    assert_raises(Erx::Error) { image.send(:domain_boots, source, given: [echo, echo]) }
  end

  # The production image carries the domain releases its manifest's domain rows and
  # session templates name. The development manifest configures the storage, network,
  # web and display domains and has a session template, so it carries the display,
  # network, session, storage and web releases, and all but the session's without the
  # template; a manifest with domain rows names each release once, and a reference of
  # another form names nothing, for the manifest check to refuse.
  def test_the_production_image_carries_the_releases_its_domain_rows_name
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    source = PLATFORM.manifest_source(ROOT)
    assert_equal %w[display network session storage web], Erx::Manifest.release_names(source: source, codec: codec)
    source = Erx::ProductionImage.without_sessions(source)
    assert_equal %w[display network storage web], Erx::Manifest.release_names(source: source, codec: codec)
    rows = %w[zeta beta zeta].each_with_index.map do |release, index|
      "domain d#{index}\n  principal @principal.system\n  limits @limits.native\n  kind service\n  flags none\n" \
        "  runtime @artifact.emu\n  release @artifact.#{release}\n  restarts 0\n  restart_period_s 0\n"
    end
    quoted = "domain q\n  principal @principal.system\n  limits @limits.native\n  kind service\n  flags none\n" \
             "  runtime @artifact.emu\n  release \"other\"\n  restarts 0\n  restart_period_s 0\n"
    assert_equal %w[beta display network storage web zeta], Erx::Manifest.release_names(source: source + rows.join + quoted, codec: codec)
  end

  # A domain row's runtime names the domain runtime image and its release a boot script
  # of the domain release, as the run of the release's entries, beside the root and the
  # release medium's EROFS image.
  def test_the_artifacts_name_the_root_the_domain_runtime_and_each_boot_script
    paths = ['boot/kernel', 'domains/erxos/bin/base.boot', 'domains/erxos/bin/session.boot', 'domains/erxos/lib/x',
             'runtimes/emu', 'system/manifest', 'system/root']
    images = { 'release' => { 'kind' => 'erofs_image' } }
    run = { 'kind' => 'release', 'entry' => 1, 'files' => 3 }
    assert_equal({ 'root' => { 'kind' => 'executable', 'entry' => 6 }, 'release' => { 'kind' => 'erofs_image' },
                   'base' => run, 'session' => run, 'emu' => { 'kind' => 'executable', 'entry' => 4 } },
                 Erx::ProductionImage.artifacts(paths, images: images))
    assert_equal({ 'root' => { 'kind' => 'executable', 'entry' => 1 } },
                 Erx::ProductionImage.artifacts(['system/manifest', 'system/root'], images: {}))
  end

  # The BeamAsm image is an executable artifact of its own, which a domain row's runtime
  # names as jit.
  def test_the_artifacts_name_the_beamasm_image
    paths = ['domains/erxos/bin/base.boot', 'runtimes/emu', 'runtimes/jit', 'system/root']
    assert_equal({ 'kind' => 'executable', 'entry' => 2 }, Erx::ProductionImage.artifacts(paths, images: {}).fetch('jit'))
  end

  def test_a_boot_script_named_as_another_artifact_is_refused
    %w[root emu release].each do |name|
      paths = ["domains/erxos/bin/#{name}.boot", 'runtimes/emu', 'system/root']
      error = assert_raises(Erx::Error) do
        Erx::ProductionImage.artifacts(paths, images: { 'release' => { 'kind' => 'erofs_image' } })
      end
      assert_includes error.message, name
    end
  end

  # A larger machine grows root_memory and system_baseline by the same amount and /tmp's
  # cap by its own, and leaves every other line alone, so the manifest check proves the
  # same properties.
  def test_a_larger_machine_grows_the_root_the_system_baseline_and_tmp_alone
    plain = PLATFORM.manifest_source(ROOT)
    source = Erx::ProductionImage.without_sessions(plain)
    refute_equal plain, source, 'the development manifest has a session template'
    refute_match(/^session /, source)
    machine = DEVELOPMENT.with(memory_mib: 2048, fiasco_reserve_mib: 160, system_growth_mib: 1024, tmp_growth_mib: 64, root_mib: 64)
    grown = machine.manifest(plain)
    { 'root_memory' => 1024, 'system_baseline' => 1024, 'tmp' => 64 }.each do |field, growth|
      assert_equal manifest_number(source, field) + (growth << 20), manifest_number(grown, field)
    end
    changed = source.lines.zip(grown.lines).reject { |old, new| old == new }.map { |old, _| old[/\A *[a-z_]+/].strip }
    assert_equal %w[tmp root_memory system_baseline], changed
    assert_equal source, DEVELOPMENT.manifest(plain)
    assert_equal PLATFORM.record, DEVELOPMENT.record, 'the development machine is the record'
    assert_equal(PLATFORM.record.merge('ram_bytes' => 2048 << 20, 'fiasco_reserve' => 160 << 20),
                 machine.record)
    wider = DEVELOPMENT.with(memory_mib: 2048, fiasco_reserve_mib: 160, system_growth_mib: 0, tmp_growth_mib: 64, root_mib: 64)
    assert_raises(Erx::Error) { wider.manifest(source) }
  end

  # A manifest without exactly one line of a grown field is refused, never left ungrown.
  def test_a_manifest_without_one_line_of_a_grown_field_is_refused
    machine = DEVELOPMENT.with(memory_mib: 1024, fiasco_reserve_mib: 96, system_growth_mib: 256, tmp_growth_mib: 0, root_mib: 64)
    ["  root_memory 1\n  system_baseline 1\n", "  system_baseline 1\n  tmp 1\n", "  root_memory 1\n  tmp 1\n",
     "  root_memory 1\n  root_memory 2\n  system_baseline 1\n  tmp 1\n"].each do |source|
      assert_raises(Erx::Error) { machine.manifest(source) }
    end
  end

  # The oracle's machine keeps the /tmp cap OTP's suite groups fill (stdlib's charge
  # about 97 MiB), whatever the development manifest's own cap.
  def test_the_oracle_machine_gives_tmp_its_160_mib
    source = PLATFORM.manifest_source(ROOT)
    assert_equal 160 << 20, manifest_number(Erx::OracleQemu.machine(PLATFORM).manifest(source), 'tmp')
  end

  # Each machine names the root's place. The development machine's lies inside its own
  # RAM and the refusal boot's, below the device tree QEMU puts at half of the development
  # machine's RAM and above the one at half of the refusal boot's; the oracle's lies high
  # enough for its large archive. A place with no room for the root is refused, and the
  # link takes only a page-aligned address in RAM.
  def test_each_machine_names_a_root_place_its_ram_holds
    development = DEVELOPMENT
    room = Erx::ProductionImage::ROOT_ROOM_MIB
    assert_equal 0x4400_0000, development.root_address
    assert_operator development.root_mib + room, :<=, development.memory_mib / 2
    assert_operator (Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB / 2) + 2, :<=, development.root_mib
    assert_operator development.root_mib + room, :<=, Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB
    assert_equal 0x4c00_0000, Erx::OracleQemu.machine(PLATFORM).root_address
    [development.memory_mib - room + 1, -1].each do |root_mib|
      assert_raises(Erx::Error) { development.with(root_mib: root_mib).root_address }
    end
    assert_equal ['--defsym=erx_fiasco_image_start=0x44000000'], Erx::NativeRoot.place_flags(0x4400_0000, ram_first: PLATFORM.ram_first)
    [0x4400_0001, 0x3fff_f000, '0x44000000'].each do |place|
      assert_raises(Erx::Error) { Erx::NativeRoot.place_flags(place, ram_first: PLATFORM.ram_first) }
    end
  end

  # The single file loads at its first stage's link address and must end at the root's
  # place, or bootstrap refuses the boot (place_overlap); the image build refuses it
  # first, naming both figures, and a file that ends exactly at the place is accepted.
  def test_a_single_file_that_reaches_the_roots_place_is_refused
    load = PLATFORM.ram_first + (2 << 20)
    room = DEVELOPMENT.root_address - load
    assert_equal room, DEVELOPMENT.check_single_file(room, load_address: load)
    error = assert_raises(Erx::Error) { DEVELOPMENT.check_single_file(room + 4096, load_address: load) }
    assert_match(/62\.00 MiB.*64 MiB into RAM/, error.message)
    assert_raises(Erx::Error) { DEVELOPMENT.check_single_file(1, load_address: DEVELOPMENT.root_address) }
  end

  # A load address below RAM (an ELF entry of 0) would leave the file a room the size of
  # everything below the root's place, so it is refused rather than measured against.
  def test_a_load_address_outside_ram_is_refused
    error = assert_raises(Erx::Error) { DEVELOPMENT.check_single_file(1, load_address: 0) }
    assert_match(/load address 0 is not in RAM/, error.message)
  end

  # The first stage's load address is the entry of a 64-bit little-endian executable ELF
  # file; a short header, another class or a file that is not an executable is refused.
  def test_the_first_stage_address_is_an_executables_entry
    header = ("\x7fELF\x02\x01\x01".b.ljust(16, "\0") + [2, 183, 1, 0x4020_0000].pack('S<S<L<Q<')).ljust(64, "\0")
    assert_equal 0x4020_0000, Erx::Fiasco.elf_entry(header)
    assert_raises(Erx::Error) { Erx::Fiasco.elf_entry(header[0, 63]) }
    assert_raises(Erx::Error) { Erx::Fiasco.elf_entry(header.sub("\x02\x01".b, "\x01\x01".b)) }
    assert_raises(Erx::Error) { Erx::Fiasco.elf_entry(header[0, 16] + [3].pack('S<') + header[18..]) }
  end

  # The website boots the site image on the machine terminal.js gives its guest, so the
  # image build packs it on that machine; it is smaller than the development machine.
  def test_the_site_machine_is_the_websites
    site = Erx::ProductionImage::Machine.site(PLATFORM)
    assert_equal [256, 16, DEVELOPMENT.root_mib], [site.memory_mib, site.fiasco_reserve_mib, site.root_mib]
    assert_operator site.memory_mib, :<, DEVELOPMENT.memory_mib
  end

  # The room line prints the smaller of the two bounds on the archive and names it.
  def test_the_room_line_names_the_bound_that_binds
    report = { 'archive_room' => { 'archive_bytes' => 50 << 20, 'archive_max_bytes' => 280 << 20,
                                   'root_memory' => 186 << 20, 'kept_bytes' => 8 << 20 },
               'manifest' => { 'promised_memory' => 178 << 20 } }
    line = ->(place) { Erx::Manifest::RootStartup.room_line(report, place_bytes: place << 20) }
    assert_match(/room for 60\.00 MiB \(the root's place binds; root_memory leaves 280\.00 MiB\)/, line.call(60))
    assert_match(/room for 280\.00 MiB \(root_memory binds; the root's place leaves 300\.00 MiB\)/, line.call(300))
  end

  # The refusal boot means something only on a machine that cannot give root_memory:
  # one no larger than root_memory, of which Fiasco and the archive take a part first.
  # The default machine leaves room for both below RAM less fiasco_reserve.
  def test_the_too_little_machine_cannot_hold_root_memory_and_the_default_can
    source = PLATFORM.manifest_source(ROOT)
    root_memory = manifest_number(source, 'root_memory')
    assert_operator Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB << 20, :<=, root_memory
    machine = DEVELOPMENT
    assert_operator root_memory, :<, (machine.memory_mib - machine.fiasco_reserve_mib) << 20
  end

  # Fiasco's kernel memory on this build (64-bit, CONFIG_KMEM_SIZE_AUTO, no -kmemsize):
  # 6% of the free memory it counts, at most RAM, rounded up to its 2 MiB superpage
  # (fiasco/kernel/src/kern/config.cpp, Config::kmem_size; arm/kmem_alloc-arm.cpp,
  # Kmem_alloc::Kmem_alloc, which passes SUPERPAGE_SIZE and takes the top of the highest
  # free region). A model of Fiasco's rule, not an oracle: the hand-kept fiasco_reserve
  # figures of the development and site machines are held to it below.
  FIASCO_KMEM_PER_CENT = 6
  FIASCO_SUPERPAGE = 2 << 20

  def fiasco_kmem_bound(memory_mib)
    kmem = (memory_mib << 20) / 100 * FIASCO_KMEM_PER_CENT
    (kmem + FIASCO_SUPERPAGE - 1) / FIASCO_SUPERPAGE * FIASCO_SUPERPAGE
  end

  # The refusal boot proves root_memory_fits, which the root reaches only once it holds the
  # contiguous pool: one run, aligned to its own size, of up to CONTIGUOUS_POOL_MAX_BYTES.
  # The run is sought only above the root's room: below it lie the archive, which may grow
  # to the root's place, and the device tree. Fiasco's kernel memory takes the top of RAM,
  # so the run must fit between the two. A machine without such a run refuses the boot at
  # the pool, and the root_memory refusal never shows.
  def test_the_refusal_machine_leaves_the_largest_contiguous_pool_its_run
    assert_equal DEVELOPMENT.fiasco_reserve_mib << 20, fiasco_kmem_bound(DEVELOPMENT.memory_mib)
    site = Erx::ProductionImage::Machine.site(PLATFORM)
    assert_equal site.fiasco_reserve_mib << 20, fiasco_kmem_bound(site.memory_mib)
    pool = Erx::Manifest::RootStartup::CONTIGUOUS_POOL_MAX_BYTES
    memory_mib = Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB
    kmem_start = PLATFORM.ram_first + (memory_mib << 20) - fiasco_kmem_bound(memory_mib)
    past_root = DEVELOPMENT.root_address + (Erx::ProductionImage::ROOT_ROOM_MIB << 20)
    run_start = (past_root + pool - 1) / pool * pool
    assert_operator run_start + pool, :<=, kmem_start,
                    "#{memory_mib} MiB leaves no #{pool >> 20} MiB run for the contiguous pool " \
                    "between the root's room and Fiasco's kernel memory"
  end

  # A root that drops system_args, or an erx.arg word, says fewer arguments than the page should hold.
  def test_the_erts_line_must_count_the_manifests_arguments_and_the_command_lines
    system_args = PLATFORM.manifest_source(ROOT)[/^\s*system_args "(.*)"$/, 1].split.size
    refute_equal 0, system_args
    # The system domain holds the host link's unit, the storage domain the block unit and
    # the network domain the net unit, so the root adds one device record to the system's:
    # the host link's physical one.
    always = Erx::ProductionImage::Run.arguments_always(ROOT) + Erx::ProductionImage::Run::DEVICE_RECORD_WORDS
    checkpoint_verifier('erts-start').call("erx: erts: erl_start runs, #{always + system_args} arguments\n")
    checkpoint_verifier('erts-start', extra_arguments: 1).call("erx: erts: erl_start runs, #{always + system_args + 1} arguments\n")
    assert_raises(Erx::Error) { checkpoint_verifier('erts-start').call("erx: erts: erl_start runs, #{always} arguments\n") }
    # Without erx.hostlink=1 the host link's UART gives no record, so the boot has one fewer.
    plain = always - Erx::ProductionImage::Run::DEVICE_RECORD_WORDS + system_args
    checkpoint_verifier('erts-start', hostlink: Erx::QemuPlan::NO_HOSTLINK).call("erx: erts: erl_start runs, #{plain} arguments\n")
    assert_raises(Erx::Error) { checkpoint_verifier('erts-start', hostlink: Erx::QemuPlan::NO_HOSTLINK).call("erx: erts: erl_start runs, #{always + system_args} arguments\n") }
  end

  # The count reads boot_info.c's ALLOCATOR_WORDS: a misread string would leave every
  # production boot's count off, so the words read must be ERTS allocator flags, each with a
  # number, and a string this reader cannot take whole fails it rather than counting short.
  def test_the_allocator_words_are_read_whole_from_boot_info
    words = Erx::ProductionImage::Run.allocator_words(ROOT)
    refute_empty words
    words.each_slice(2) do |flag, value|
      assert_match(/\A-M[A-Za-z]+\z/, flag)
      assert_match(/\A\d+\z/, value.to_s)
    end
    # Another escape, a trailing \0 (an empty word to C), an octal escape C reads as one
    # character, and a declaration only quoted in a comment.
    refused = ['"-MMmcs\\0" "2\\n"', '"-MMmcs\\0" "2\\0"', '"-MMmcs\\012"']
    Dir.mktmpdir('erx-boot-info-') do |root|
      path = File.join(root, Erx::ProductionImage::Run::BOOT_INFO)
      FileUtils.mkdir_p(File.dirname(path))
      (refused.map { |literals| "static const char ALLOCATOR_WORDS[] = #{literals};\n" } +
       [%(/* static const char ALLOCATOR_WORDS[] = "-MMmcs\\0" "2"; */\n)]).each do |source|
        File.write(path, source)
        assert_raises(Erx::Error, source) { Erx::ProductionImage::Run.allocator_words(root) }
      end
    end
  end

  # The root gives a device record to each device that matches a row of erx/device_kinds.h's
  # erx_device_kinds table and to the host link's UART, so a row added there whose role word is
  # not in RECORD_UNITS would leave every production boot's argument count one record short.
  # Every row is read, and a row this test cannot read fails it rather than going unseen, as
  # does a row that does not name both a role word and a peripheral: erx_dom_entry_driven
  # (erx/dom.h) asks only for the role word, and the record writes both. Rows
  # of two controllers may share a role word, as virtio-mmio's and GENET's share net.
  def test_the_record_units_are_the_roots_device_kinds_and_the_host_link
    table = File.read(File.join(ROOT, 'include/erx/device_kinds.h'))[/erx_device_kinds\[\] = \{\n(.*?)^\};/m, 1]
    rows = table.lines.grep(/\A\s*\{/)
    words = rows.map { |row| row[/\A\s*\{\s*ERX_MF_DEVICE_ROLE_\w+,\s*"[^"]*",\s*"(\w+)",\s*"\w+"\s*\}/, 1] }
    refute_empty words
    refute_includes words, nil
    assert_equal [*words.uniq, Erx::ProductionImage::Run::HOSTLINK_UNIT].sort, Erx::ProductionImage::Run::RECORD_UNITS.sort
  end

  # A scheduler short of a CPU, or started as a worker, leaves the count wrong or the line unsaid.
  def test_the_executors_line_must_count_a_scheduler_per_cpu
    verify = checkpoint_verifier('erts-executors')
    verify.call("erx: erts: 4 schedulers and 4 dirty CPU schedulers hold executor slots\n")
    assert_raises(Erx::Error) { verify.call("erx: erts: 1 schedulers and 4 dirty CPU schedulers hold executor slots\n") }
    assert_raises(Erx::Error) { verify.call("erx: erts: 4 schedulers and 1 dirty CPU schedulers hold executor slots\n") }
  end

  # The narrow manifest puts every share on two CPUs at most, so a machine of four runs two schedulers:
  # a count taken from the online CPUs alone says four and fails.
  def test_the_narrow_image_counts_schedulers_from_the_share_and_the_online_cpus
    narrow = Erx::ProductionImage::Run.narrow_manifest(ROOT, platform: PLATFORM)
    assert_match(/^share system\n(?:  .*\n)*?  cpuset 3$/, narrow)
    assert_match(/^share users\n(?:  .*\n)*?  cpuset 3$/, narrow)
    assert_match(/^share system\n  quota_ns 20000000$/, narrow)
    assert_raises(Erx::Error) { Erx::ProductionImage::Run.narrow_share("share far\n  quota_ns 5000000\n  period_ns 10000000\n  cpuset 12\n") }
    verify = checkpoint_verifier("erts-executors", manifest_source: narrow)
    verify.call("erx: erts: 2 schedulers and 2 dirty CPU schedulers hold executor slots\n")
    assert_raises(Erx::Error) { verify.call("erx: erts: 4 schedulers and 4 dirty CPU schedulers hold executor slots\n") }
  end

  # A stopped pet ends the machine about the pet deadline later: at once or much later is a fault.
  def test_a_stopped_pet_must_end_the_machine_about_the_pet_deadline_later
    run = Erx::ProductionImage::Run.allocate
    proof = Erx::ProductionImage::Run::PET_PROOF.fetch("hvf")
    at = ->(stopped, fired) { [{ 'name' => 'pet-stopped', 'elapsed_seconds' => stopped }, { 'name' => 'watchdog-fired', 'elapsed_seconds' => fired }] }
    assert_nil run.send(:judge_missed_pet_time, at.call(100.0, 105.5), proof)
    assert_raises(Erx::Error) { run.send(:judge_missed_pet_time, at.call(100.0, 101.0), proof) }
    assert_raises(Erx::Error) { run.send(:judge_missed_pet_time, at.call(100.0, 160.0), proof) }
  end

  def test_the_watchdog_line_must_carry_what_the_command_line_says
    verify = checkpoint_verifier('root-watchdog')
    verify.call("erx: root task: watchdog 1,30,600\n")
    assert_raises(Erx::Error) { verify.call("erx: root task: watchdog 10,60,60\n") }
  end

  def test_a_command_line_reaches_qemu_only_when_asked
    plan = { platform: PLATFORM, accel: 'tcg', image: '/image', serial: '/serial', hostlink: Erx::QemuPlan::NO_HOSTLINK }
    refute_includes Erx::QemuPlan.argv(**plan), '-append'
    assert_equal %w[-append erx.det=1], Erx::QemuPlan.argv(**plan, command_line: 'erx.det=1').last(2)
  end

  def test_the_manifest_line_must_carry_the_sources_numbers
    verify = checkpoint_verifier('root-manifest')
    source = PLATFORM.manifest_source(ROOT)
    memory, baseline = manifest_number(source, 'root_memory'), manifest_number(source, 'system_baseline')
    units = source.scan(/^unit /).size
    verify.call("erx: root task: manifest root_memory #{memory} baseline #{baseline} units #{units} pool pages 12 image 4096\n")
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory 1 baseline #{baseline} units #{units} pool pages 12 image 4096\n") }
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory #{memory} baseline 1 units #{units} pool pages 12 image 4096\n") }
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory #{memory} baseline #{baseline} units #{units + 1} pool pages 12 image 4096\n") }
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory #{memory} baseline #{baseline} units #{units} pool pages 12\n") }
  end

  # A boot of the development image at 256 MiB (the Apple M3 Max host, HVF, 1 guest CPU,
  # QEMU 11.1.3): its archive, and the pool pages and root image its root reported. It
  # kept 4,321,280 bytes besides the archive and the page index, 2,224,128 besides its
  # 2 MiB contiguous pool too, for the 1.25 MiB of devices' memory its manifest declares.
  LOGGED_ARCHIVE = 0x2dfb000
  LOGGED_POOL_PAGES = 46_858
  LOGGED_IMAGE = 0x4dc000
  LOGGED_DMA_MEMORY = 1_310_720
  # The machine that boot ran on: 256 MiB, of which Fiasco kept 16 MiB.
  LOGGED_MACHINE = DEVELOPMENT.with(memory_mib: 256, fiasco_reserve_mib: 16)

  def kept_verifier(machine)
    Dir.mktmpdir('erx-kept-') do |directory|
      archive = File.join(directory, 'image.pack')
      File.open(archive, 'wb') { |file| file.truncate(LOGGED_ARCHIVE) }
      built = FakeArchiveBuilt.new(build_id: 'aa', index_hash: 'bb', flags: 1, test_code: false, archive: archive,
                                   report: { 'manifest' => { 'dma_memory' => LOGGED_DMA_MEMORY } })
      points = Erx::ProductionImage::Run.checkpoints(built, root: ROOT, watchdog: '1,30,600', cpus: 1,
                                                     manifest_source: PLATFORM.manifest_source(ROOT),
                                                     memory_mib: machine.memory_mib)
      assert_raises(Erx::Error) { Erx::ProductionImage::Run.kept_checkpoints(points.reject { |each| each.fetch(:name) == 'root-manifest' }, built: built, machine: machine) }
      Erx::ProductionImage::Run.kept_checkpoints(points, built: built, machine: machine)
                               .find { |each| each.fetch(:name) == 'root-manifest' }.fetch(:verify)
    end
  end
  FakeArchiveBuilt = Struct.new(:build_id, :index_hash, :flags, :test_code, :archive, :report, keyword_init: true)

  # The production image suite holds each boot to what the packer counts it keeps. The
  # seeded fault is a record whose root_withheld is a page less than that boot kept.
  def test_the_suite_refuses_a_boot_that_keeps_more_than_the_packer_counts
    source = PLATFORM.manifest_source(ROOT)
    line = "erx: root task: manifest root_memory #{manifest_number(source, 'root_memory')} baseline " \
           "#{manifest_number(source, 'system_baseline')} units #{source.scan(/^unit /).size} " \
           "pool pages #{LOGGED_POOL_PAGES} image #{LOGGED_IMAGE}\r\n"
    kept_verifier(LOGGED_MACHINE).call(line)
    short = Erx::Platform.new(name: PLATFORM.name, record: PLATFORM.record.merge('root_withheld' => 2_224_128 - 4096))
    error = assert_raises(Erx::Error) { kept_verifier(LOGGED_MACHINE.with(platform: short)).call(line) }
    assert_match(/the boot kept 6418432 bytes besides the archive, 4096 more than .*root_withheld 2220032 is too small/, error.message)
    refute_kind_of Erx::Manifest::Invalid, error
    assert_raises(Erx::Error) { kept_verifier(DEVELOPMENT).call(line.sub("pool pages #{LOGGED_POOL_PAGES}", 'pool pages 99999999')) }
  end

  # A build/production-image that links out of the tree is refused before
  # anything is removed, so the harness never deletes what the link names.
  def test_an_image_directory_through_a_link_is_refused_before_removal
    Dir.mktmpdir('erx-image-clear-') do |scratch|
      tree = File.join(scratch, 'tree')
      outside = File.join(scratch, 'outside')
      FileUtils.mkdir_p([File.join(tree, 'build'), File.join(outside, 'boot')])
      File.write(File.join(outside, 'boot', 'keep'), 'not the tree')
      File.symlink(outside, File.join(tree, 'build/production-image'))
      run = Erx::ProductionImage::Run.new(root: tree, runner: Object.new, platform: PLATFORM)
      assert_raises(Erx::Error) { run.send(:image, nil) }
      assert File.file?(File.join(outside, 'boot', 'keep'))
      assert_raises(Erx::Error) do
        Erx::ProductionImage.clear_directory(root: tree, path: File.join(tree, 'build/production-image/interactive'))
      end
      assert_raises(Erx::Error) { Erx::ProductionImage.clear_directory(root: tree, path: tree) }
      assert File.directory?(File.join(tree, 'build'))
    end
  end

  # TCG runs only the smoke: asked for the whole matrix, the run refuses before it builds.
  def test_the_whole_matrix_refuses_tcg
    run = Erx::ProductionImage::Run.allocate.tap { |instance| instance.instance_variable_set(:@root, ROOT) }
    error = assert_raises(Erx::Error) { run.call(accels: %w[hvf tcg]) }
    assert_match(/TCG runs only the smoke/, error.message)
    assert_raises(Erx::Error) { run.call(accels: %w[kvm]) }
  end

  private

  def manifest_number(text, field) = Integer(text[/^  #{field} ([0-9]+)$/, 1], 10)
end
