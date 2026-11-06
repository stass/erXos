# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'minitest/autorun'
require 'open3'
require 'pathname'
require 'rbconfig'
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
  # code, and the source check holds its one caller (Checks::TEST_IMAGE_BUILDER).
  def test_the_production_build_takes_no_additions
    production = Erx::ProductionImage.instance_method(:build).parameters
    refute_includes production.map(&:last), :added
    assert_equal [%i[keyreq directory], %i[keyreq added]], Erx::ProductionImage.instance_method(:build_test_image).parameters
  end

  # A root that drops system_args, or an erx.arg word, says fewer arguments than the page should hold.
  def test_the_erts_line_must_count_the_manifests_arguments_and_the_command_lines
    system_args = File.read(File.join(ROOT, Erx::ProductionImage::MANIFEST))[/^\s*system_args "(.*)"$/, 1].split.size
    refute_equal 0, system_args
    always = Erx::ProductionImage::Run::ARGUMENTS_ALWAYS
    checkpoint_verifier('erts-start').call("erx: erts: erl_start runs, #{always + system_args} arguments\n")
    checkpoint_verifier('erts-start', extra_arguments: 1).call("erx: erts: erl_start runs, #{always + system_args + 1} arguments\n")
    assert_raises(Erx::Error) { checkpoint_verifier('erts-start').call("erx: erts: erl_start runs, #{always} arguments\n") }
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
    proof = Erx::ProductionImage::Run::PET_PROOF.fetch("tcg")
    at = ->(stopped, fired) { [{ 'name' => 'pet-stopped', 'elapsed_seconds' => stopped }, { 'name' => 'watchdog-fired', 'elapsed_seconds' => fired }] }
    assert_nil run.send(:judge_missed_pet_time, at.call(100.0, 130.5), proof)
    assert_raises(Erx::Error) { run.send(:judge_missed_pet_time, at.call(100.0, 101.0), proof) }
    assert_raises(Erx::Error) { run.send(:judge_missed_pet_time, at.call(100.0, 160.0), proof) }
  end

  def test_the_watchdog_line_must_carry_what_the_command_line_says
    verify = checkpoint_verifier('root-watchdog')
    verify.call("erx: root task: watchdog 1,30,600\n")
    assert_raises(Erx::Error) { verify.call("erx: root task: watchdog 10,60,60\n") }
  end

  def test_a_command_line_reaches_qemu_only_when_asked
    plan = { accel: 'tcg', image: '/image', serial: '/serial' }
    refute_includes Erx::QemuPlan.argv(**plan), '-append'
    assert_equal %w[-append erx.det=1], Erx::QemuPlan.argv(**plan, command_line: 'erx.det=1').last(2)
  end

  def test_the_manifest_line_must_carry_the_sources_numbers
    verify = checkpoint_verifier('root-manifest')
    verify.call("erx: root task: manifest root_memory 402653184 baseline 134217728 units 3 pool pages 12\n")
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory 1 baseline 134217728 units 3 pool pages 12\n") }
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
end
