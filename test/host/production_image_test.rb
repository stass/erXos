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
    \t};

    \tvirtio_mmio@a003e00 {
    \t\tcompatible = "virtio,mmio";
    \t};
    };
  DTS

  def platform(path:, compatible: 'arm,pl011')
    { 'units' => [{ 'devices' => [{ 'path' => path, 'compatible' => compatible }] }] }
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
    assert_empty Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9000000'), TREE)
    assert_empty Erx::ProductionImage.device_path_problems(platform(path: '/virtio_mmio@a003e00', compatible: 'virtio,mmio'), TREE)
  end

  def test_a_path_the_tree_lacks_is_named
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/pl011@9040000'), TREE)
    assert_equal ['/pl011@9040000: not in the device tree'], problems
  end

  def test_a_node_of_another_kind_is_named
    problems = Erx::ProductionImage.device_path_problems(platform(path: '/virtio_mmio@a003e00'), TREE)
    assert_match(/compatible .* does not name arm,pl011/, problems.fetch(0))
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

  def checkpoint_verifier(name, **options)
    built = Struct.new(:build_id, :index_hash).new('aa', 'bb')
    points = Erx::ProductionImage::Run.checkpoints(built, root: ROOT, watchdog: '1,30,600', cpus: 4, **options)
    points.find { |point| point.fetch(:name) == name }.fetch(:verify)
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

  # The boot's last line is init's own refusal, and no other way of ending counts.
  def test_the_last_line_must_be_inits_refusal_of_the_missing_boot_script
    verify = checkpoint_verifier('erts-init-runs')
    verify.call("Runtime terminating during boot ({'cannot get bootfile','/bin/start.boot'})\n")
    assert_raises(Erx::Error) { verify.call("Runtime terminating during boot ({badmatch,1})\n") }
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
end
