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

# The production image's host-side rules. Its boot is the QEMU gate's production_image suite.
class ProductionImageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TREE = <<~DTS
    /dts-v1/;

    / {
    \tpl011@9000000 {
    \t\tclock-names = "uartclk", "apb_pclk";
    \t\tcompatible = "arm,pl011", "arm,primecell";
    \t\treg = <0x00 0x9000000 0x00 0x1000>;
    \t\tinterrupts = <0x00 0x01 0x04>;
    \t};

    \tvirtio_mmio@a003e00 {
    \t\tcompatible = "virtio,mmio";
    \t\treg = <0x00 0xa003e00 0x00 0x200>;
    \t\tinterrupts = <0x00 0x2f 0x01>;
    \t};
    };
  DTS

  UART_WINDOW = { base: 0x9000000, size: 0x1000, line: 33 }.freeze
  BLOCK_WINDOW = { base: 0xa003e00, size: 0x200, line: 79 }.freeze

  def platform(path:, compatible: 'arm,pl011', **window)
    { 'units' => [{ 'devices' => [{ 'selector' => 'dt', 'path' => path, 'compatible' => compatible, **window.transform_keys(&:to_s) }] }] }
  end

  def test_every_import_the_root_links_is_registered
    linked = Erx::NativeRoot::SERVICE.filter_map do |source|
      Pathname(source).ascend.map(&:to_s).find { |directory| File.file?(File.join(ROOT, directory, 'ORIGIN.md')) }
    end
    assert_empty linked.uniq - Erx::ProductionImage::IMPORTS.keys
  end

  # libbeam.a holds littlefs's objects (lfs.o and lfs_util.o, in the emulator's OS_OBJS), so
  # its attribution names littlefs's licence beside OTP's; every notice named is a tree file.
  def test_emulator_archive_carries_the_littlefs_notice
    fiasco = Struct.new(:boot_core_archive) { def user_library(name) = "/fiasco/#{name}" }.new('/fiasco/boot_cores.a')
    erts = Erx::NativeRuntime::Built.new(otp_archives: ['/otp/erl_main.o', '/otp/libbeam.a'], libc: '/musl/libc.a', otp: '/otp')
    image = Erx::ProductionImage.new(root: ROOT, runner: nil, compiler: '', linker: '', fiasco: fiasco, runtime: nil)
    archives = image.send(:archives, erts).to_h { |archive| [File.basename(archive.path), archive] }
    assert_equal 'Apache-2.0 AND BSD-3-Clause', archives.fetch('libbeam.a').license
    assert_equal %w[otp/LICENSE.txt littlefs/LICENSE.md], archives.fetch('libbeam.a').notices
    assert_equal %w[otp/LICENSE.txt], archives.fetch('erl_main.o').notices
    makefile = File.read(File.join(ROOT, 'otp/erts/emulator/Makefile.in'))
    assert_match %r{^LFS_DIR = \$\(ERX_TREE\)/littlefs$}, makefile
    archives.values.flat_map(&:notices).each { |notice| assert File.file?(File.join(ROOT, notice)), notice }
  end

  # The dedication in each ChaCha20 file's header is the only licence statement it holds, and
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

  def test_a_row_without_its_window_is_named
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000'), TREE)
    assert_match(/base, size or line .* differ/, problems.fetch(0))
  end

  # A device tree path's unit address is its node's first reg address, so the checked-in
  # record's base must agree with its own path without QEMU to ask.
  def test_each_recorded_base_is_its_paths_unit_address
    record = JSON.parse(File.read(File.join(ROOT, Erx::ProductionImage::PLATFORM)))
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
    point = Erx::ProductionImage::Run.stdout_path_refusal_checkpoints.last
    line = "erx: root task refused the boot: manifest: the console /pl011@9000000 is not the node /chosen/stdout-path names, /uart@9000000\r\n"
    assert_match point.fetch(:pattern), line
    refute_match point.fetch(:pattern), line.sub('/uart@9000000', '(none)')
  end

  FakeBuilt = Struct.new(:build_id, :index_hash, :flags, :test_code, keyword_init: true)

  def checkpoint_verifier(name, built: FakeBuilt.new(build_id: 'aa', index_hash: 'bb', flags: 1, test_code: false), **options)
    points = Erx::ProductionImage::Run.checkpoints(built, root: ROOT, watchdog: '1,30,600', cpus: 4, **options)
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

    console = run.console_checkpoints
    assert_equal "erl\r", console.find { |point| point.fetch(:name) == 'development-warning' }.fetch(:type)
    release, shell = shells.call(console)
    assert_equal [%w[release-shell shell], nil, "1+1.\r"], [[release, shell].map { |point| point.fetch(:name) }, release[:type], shell[:type]]
    assert_match release.fetch(:pattern), rc
    assert_match shell.fetch(:pattern), eshell
    menu, left = %w[ctrl-g-menu menu-left].map { |name| console.find { |point| point.fetch(:name) == name } }
    assert_equal [run::ESC, "1+2\x7f3.\r"], [menu, left].map { |point| point.fetch(:type) }
    assert_match menu.fetch(:pattern), "erx_console: Ctrl-G menu\r\n"
    assert_match left.fetch(:pattern), "Esc returns. \e\\\e[0m\r\n"

    release, erlang = shells.call(run.idle_checkpoints(cpus: 1, root: ROOT))
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
    points = run.kernel_record_checkpoints(cpus: 4)
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
    machine_summary = '[{cpus_online,{kernel,{ok,4}}},{memory_free,{{stopgap,liberx_pool},{partial,8192}}},' \
                      '{memory_total,{{stopgap,liberx_pool},{partial,65536}}},{uptime,{kernel,{ok,1234}}}]'
    good = "{object_info,#{machine_summary},{ok,4,[]},#{group}," \
           "[{used,{{stopgap,liberx_pool},{partial,812}}}],{ok,9,[]}}\r\n"
    verify.call(good)
    verify.call("3> #{good}")
    { 'cpus_online unsupported' => good.sub('[{cpus_online,{kernel,{ok,4}}},', '['),
      'uptime unsupported' => good.sub(',{uptime,{kernel,{ok,1234}}}', ''),
      'memory reported as the kernel' => good.sub('{memory_total,{{stopgap,liberx_pool},{partial,65536}}}',
                                                  '{memory_total,{kernel,{ok,65536}}}'),
      'free memory of zero' => good.sub('{partial,8192}', '{partial,0}'),
      'another CPU count' => good.sub('{cpus_online,{kernel,{ok,4}}}', '{cpus_online,{kernel,{ok,1}}}'),
      'another machine attribute reported' => good.sub('[{cpus_online,', '[{build,{kernel,{ok,1}}},{cpus_online,'),
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
    assert_equal [%i[keyreq directory], %i[keyreq added], %i[key machine], %i[key domains]],
                 Erx::ProductionImage.instance_method(:build_test_image).parameters
  end

  # The production image carries the domain releases its manifest's domain rows and
  # session templates name. The development manifest configures no domains, so it carries
  # only its session template's, the session release; a manifest with domain rows names
  # each release once, and a reference of another form names nothing, for the manifest
  # check to refuse.
  def test_the_production_image_carries_the_releases_its_domain_rows_name
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    source = File.binread(File.join(ROOT, Erx::ProductionImage::MANIFEST))
    assert_equal ['session'], Erx::Manifest.release_names(source: source, codec: codec)
    source = Erx::ProductionImage.without_sessions(source)
    assert_empty Erx::Manifest.release_names(source: source, codec: codec)
    rows = %w[zeta beta zeta].each_with_index.map do |release, index|
      "domain d#{index}\n  principal @principal.system\n  limits @limits.native\n  kind service\n  flags none\n" \
        "  runtime @artifact.emu\n  release @artifact.#{release}\n  restarts 0\n  restart_period_s 0\n"
    end
    quoted = "domain q\n  principal @principal.system\n  limits @limits.native\n  kind service\n  flags none\n" \
             "  runtime @artifact.emu\n  release \"other\"\n  restarts 0\n  restart_period_s 0\n"
    assert_equal %w[beta zeta], Erx::Manifest.release_names(source: source + rows.join + quoted, codec: codec)
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
    plain = File.binread(File.join(ROOT, Erx::ProductionImage::MANIFEST))
    source = Erx::ProductionImage.without_sessions(plain)
    refute_equal plain, source, 'the development manifest has a session template'
    refute_match(/^session /, source)
    machine = Erx::ProductionImage::Machine.new(memory_mib: 2048, fiasco_reserve_mib: 160, system_growth_mib: 1024, tmp_growth_mib: 64, root_mib: 64)
    grown = machine.manifest(plain)
    { 'root_memory' => 1024, 'system_baseline' => 1024, 'tmp' => 64 }.each do |field, growth|
      assert_equal manifest_number(source, field) + (growth << 20), manifest_number(grown, field)
    end
    changed = source.lines.zip(grown.lines).reject { |old, new| old == new }.map { |old, _| old[/\A *[a-z_]+/].strip }
    assert_equal %w[tmp root_memory system_baseline], changed
    assert_equal source, Erx::ProductionImage::DEVELOPMENT_MACHINE.manifest(plain)
    record = JSON.parse(File.read(File.join(ROOT, Erx::ProductionImage::PLATFORM)))
    assert_equal record, Erx::ProductionImage::DEVELOPMENT_MACHINE.platform(record), 'the development machine is the record'
    assert_equal({ 'ram_bytes' => 2048 << 20, 'fiasco_reserve' => 160 << 20, 'units' => [] },
                 machine.platform('ram_bytes' => 1, 'fiasco_reserve' => 1, 'units' => []))
    wider = Erx::ProductionImage::Machine.new(memory_mib: 2048, fiasco_reserve_mib: 160, system_growth_mib: 0, tmp_growth_mib: 64, root_mib: 64)
    assert_raises(Erx::Error) { wider.manifest(source) }
  end

  # A manifest without exactly one line of a grown field is refused, never left ungrown.
  def test_a_manifest_without_one_line_of_a_grown_field_is_refused
    machine = Erx::ProductionImage::Machine.new(memory_mib: 1024, fiasco_reserve_mib: 96, system_growth_mib: 256, tmp_growth_mib: 0, root_mib: 64)
    ["  root_memory 1\n  system_baseline 1\n", "  system_baseline 1\n  tmp 1\n", "  root_memory 1\n  tmp 1\n",
     "  root_memory 1\n  root_memory 2\n  system_baseline 1\n  tmp 1\n"].each do |source|
      assert_raises(Erx::Error) { machine.manifest(source) }
    end
  end

  # The oracle's machine keeps the /tmp cap OTP's suite groups fill (stdlib's charge
  # about 97 MiB), whatever the development manifest's own cap.
  def test_the_oracle_machine_gives_tmp_its_160_mib
    source = File.binread(File.join(ROOT, Erx::ProductionImage::MANIFEST))
    assert_equal 160 << 20, manifest_number(Erx::OracleQemu::MACHINE.manifest(source), 'tmp')
  end

  # Each machine names the root's place. The development machine's lies inside its own
  # RAM and the refusal boot's, below the device tree QEMU puts at half of a 160 MiB
  # machine's RAM and above the one at half of the refusal boot's; the oracle's lies high
  # enough for its large archive. A place with no room for the root is refused, and the
  # link takes only a page-aligned address in RAM.
  def test_each_machine_names_a_root_place_its_ram_holds
    development = Erx::ProductionImage::DEVELOPMENT_MACHINE
    room = Erx::ProductionImage::ROOT_ROOM_MIB
    assert_equal 0x4400_0000, development.root_address
    assert_operator development.root_mib + room, :<=, development.memory_mib / 2
    assert_operator (Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB / 2) + 2, :<=, development.root_mib
    assert_operator development.root_mib + room, :<=, Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB
    assert_equal 0x4c00_0000, Erx::OracleQemu::MACHINE.root_address
    [development.memory_mib - room + 1, -1].each do |root_mib|
      assert_raises(Erx::Error) { development.with(root_mib: root_mib).root_address }
    end
    assert_equal ['--defsym=erx_fiasco_image_start=0x44000000'], Erx::NativeRoot.place_flags(0x4400_0000)
    [0x4400_0001, 0x3fff_f000, '0x44000000'].each do |place|
      assert_raises(Erx::Error) { Erx::NativeRoot.place_flags(place) }
    end
  end

  # The refusal boot means something only on a machine that cannot give root_memory:
  # one no larger than root_memory, of which Fiasco and the archive take a part first.
  # The default machine leaves room for both below RAM less fiasco_reserve.
  def test_the_too_little_machine_cannot_hold_root_memory_and_the_default_can
    source = File.binread(File.join(ROOT, Erx::ProductionImage::MANIFEST))
    root_memory = manifest_number(source, 'root_memory')
    assert_operator Erx::ProductionImage::TOO_LITTLE_MEMORY_MIB << 20, :<=, root_memory
    machine = Erx::ProductionImage::DEVELOPMENT_MACHINE
    assert_operator root_memory, :<, (machine.memory_mib - machine.fiasco_reserve_mib) << 20
  end

  # A root that drops system_args, or an erx.arg word, says fewer arguments than the page should hold.
  def test_the_erts_line_must_count_the_manifests_arguments_and_the_command_lines
    system_args = File.read(File.join(ROOT, Erx::ProductionImage::MANIFEST))[/^\s*system_args "(.*)"$/, 1].split.size
    refute_equal 0, system_args
    # The manifest has a block unit, a net unit and the host link's, so the root adds three
    # device records: two given and the host link's physical one.
    always = Erx::ProductionImage::Run.arguments_always(ROOT) + (2 * Erx::ProductionImage::Run::GIVEN_RECORD_WORDS) +
             Erx::ProductionImage::Run::DEVICE_RECORD_WORDS
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
  # Every row is read, and a row this test cannot read fails it rather than going unseen.
  def test_the_record_units_are_the_roots_device_kinds_and_the_host_link
    table = File.read(File.join(ROOT, 'include/erx/device_kinds.h'))[/erx_device_kinds\[\] = \{\n(.*?)^\};/m, 1]
    rows = table.lines.grep(/\A\s*\{/)
    words = rows.map { |row| row[/\A\s*\{\s*ERX_MF_DEVICE_ROLE_\w+,\s*"[^"]*",\s*"(\w+)"/, 1] }
    refute_empty words
    refute_includes words, nil
    assert_equal [*words, Erx::ProductionImage::Run::HOSTLINK_UNIT].sort, Erx::ProductionImage::Run::RECORD_UNITS.sort
  end

  # A scheduler short of a CPU, or started as a worker, leaves the count wrong or the line unsaid.
  def test_the_executors_line_must_count_a_scheduler_per_cpu
    verify = checkpoint_verifier('erts-executors')
    verify.call("erx: erts: 4 schedulers and 4 dirty CPU schedulers hold executor slots\n")
    assert_raises(Erx::Error) { verify.call("erx: erts: 1 schedulers and 4 dirty CPU schedulers hold executor slots\n") }
    assert_raises(Erx::Error) { verify.call("erx: erts: 4 schedulers and 1 dirty CPU schedulers hold executor slots\n") }
  end

  # The narrow manifest puts the system share on two CPUs, so a machine of four runs two schedulers:
  # a count taken from the online CPUs alone says four and fails.
  def test_the_narrow_image_counts_schedulers_from_the_share_and_the_online_cpus
    run = Erx::ProductionImage::Run.allocate.tap { |instance| instance.instance_variable_set(:@root, ROOT) }
    narrow = run.send(:narrow_manifest)
    assert_match(/^share system\n(?:  .*\n)*?  cpuset 3$/, narrow)
    assert_match(/^share users\n(?:  .*\n)*?  cpuset 15$/, narrow)
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
    plan = { accel: 'tcg', image: '/image', serial: '/serial', hostlink: Erx::QemuPlan::NO_HOSTLINK }
    refute_includes Erx::QemuPlan.argv(**plan), '-append'
    assert_equal %w[-append erx.det=1], Erx::QemuPlan.argv(**plan, command_line: 'erx.det=1').last(2)
  end

  def test_the_manifest_line_must_carry_the_sources_numbers
    verify = checkpoint_verifier('root-manifest')
    source = File.binread(File.join(ROOT, Erx::ProductionImage::MANIFEST))
    memory, baseline = manifest_number(source, 'root_memory'), manifest_number(source, 'system_baseline')
    verify.call("erx: root task: manifest root_memory #{memory} baseline #{baseline} units 4 pool pages 12\n")
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory 1 baseline #{baseline} units 4 pool pages 12\n") }
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory #{memory} baseline 1 units 4 pool pages 12\n") }
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
      run = Erx::ProductionImage::Run.new(root: tree, runner: Object.new)
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
