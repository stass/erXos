# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
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

  def test_the_manifest_line_must_carry_the_sources_numbers
    built = Struct.new(:build_id, :index_hash).new('aa', 'bb')
    points = Erx::ProductionImage::Run.checkpoints(built, root: ROOT)
    verify = points.find { |point| point.fetch(:name) == 'root-manifest' }.fetch(:verify)
    verify.call("erx: root task: manifest root_memory 402653184 baseline 134217728 units 3 pool pages 12\n")
    assert_raises(Erx::Error) { verify.call("erx: root task: manifest root_memory 1 baseline 134217728 units 3 pool pages 12\n") }
  end
end
