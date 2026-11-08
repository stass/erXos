# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/structural_pack'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/pack'
require_relative '../../tools/lib/erx/toolchain_provenance'

class StructuralPackTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    scratch = File.join(@root, 'build/test')
    FileUtils.mkdir_p(scratch)
    @directory = Dir.mktmpdir('structural-pack-', scratch)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    @compiler = ENV.fetch('ERX_CLANG', 'clang')
    @linker = ENV.fetch('ERX_LLD', 'ld.lld')
    @tools = Erx::PackTools.build(root: @root, owner_root: @directory, directory: File.join(@directory, 'tools'),
                                  runner: @runner, compiler: @compiler, sanitizers: %w[address undefined])
    resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
    @external = Erx::ToolchainProvenance.llvm(root: @root, resource_dir: File.read(resource.fetch('log')).strip)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
  end

  def fixture(name)
    StructuralPackFixture.build(root: @root, directory: File.join(@directory, name), codec: @codec,
                                runner: @runner, tools: @tools, compiler: @compiler,
                                linker: @linker, external: @external)
  end

  def test_full_structural_wire_fixture_is_byte_identical_across_clean_builds
    first = fixture('first')
    second = fixture('second')
    left = first.fetch('report')
    right = second.fetch('report')
    assert_equal 'structural_test_fixture', left.fetch('kind')
    assert_equal File.binread(left.fetch('path')), File.binread(right.fetch('path'))
    assert_equal File.binread(left.fetch('single_path')), File.binread(right.fetch('single_path'))
    assert File.binread(left.fetch('single_path')).end_with?(File.binread(left.fetch('path')))
    assert_equal left.fetch('sha256'), right.fetch('sha256')
    assert_equal left.fetch('manifest_sha256'), right.fetch('manifest_sha256')
    assert_equal first.fetch('context').fingerprint, second.fetch('context').fingerprint
    %w[structure executable provenance].each { |check| assert_equal 'validated', left.fetch(check) }
    %w[root_startup policy_admission].each { |check| assert_equal 'unsupported', left.fetch(check) }
    assert_equal 0, left.fetch('child_plan_instances')
    assert_equal 3, left.fetch('entries')
    bytes = File.binread(left.fetch('path'))
    assert_equal "ERXPACK\0".b, bytes.byteslice(0, 8)
    header = @codec.decode_layout('erx_pack_header', bytes)
    assert_equal bytes.bytesize, header.fetch('total_size')
    assert_operator bytes.bytesize % @codec.constant('page_size'), :==, 0
    assert_operator first.fetch('provenance').size, :>, 11
  end

  def test_a_platform_without_the_reserve_is_not_admitted_and_preserves_existing_output
    structural = fixture('structural')
    native = structural.fetch('native')
    output = File.join(@directory, 'production.erxpack')
    File.binwrite(output, 'existing output')
    planner = Erx::ElfPlanner.new(helper: @tools.fetch('planner'), runner: @runner, codec: @codec)
    resolver = Erx::PackProvenance.new(root: @root, catalog: native.fetch('catalog'), external: @external, runner: @runner)
    production = Erx::Pack.new(root: @root, output_root: @directory, codec: @codec, planner: planner,
                               checker: @tools.fetch('checker'), hasher: @tools.fetch('hasher'), runner: @runner,
                               provenance: resolver)
    entries = [{ 'path' => 'system/root', 'kind' => @codec.member('entry_kind', 'image'),
                 'flags' => @codec.member('entry_flags', 'system'), 'id' => 'root',
                 'artifact' => native.fetch('artifact'), 'receipt' => native.fetch('receipt') }]
    error = assert_raises(Erx::Manifest::Unsupported) do
      production.build(entries: entries, root_path: 'system/root', build_kind: 'development',
                       platform: ManifestContextFixture.platform,
                       artifacts: { 'root' => { 'kind' => 'executable', 'entry' => 2 } }.merge(ManifestContextFixture.images),
                       manifest_source: structural.fetch('manifest_source'), output: output)
    end
    assert_equal 4, error.property
    assert_equal 'root_startup', error.field
    assert_equal 'existing output', File.binread(output)
  end

  def test_the_real_development_manifest_is_admitted_and_packed
    native = fixture('admitted').fetch('native')
    planner = Erx::ElfPlanner.new(helper: @tools.fetch('planner'), runner: @runner, codec: @codec)
    resolver = Erx::PackProvenance.new(root: @root, catalog: native.fetch('catalog'), external: @external, runner: @runner)
    production = Erx::Pack.new(root: @root, output_root: @directory, codec: @codec, planner: planner,
                               checker: @tools.fetch('checker'), hasher: @tools.fetch('hasher'), runner: @runner,
                               provenance: resolver)
    entries = [{ 'path' => 'system/root', 'kind' => @codec.member('entry_kind', 'image'),
                 'flags' => @codec.member('entry_flags', 'system'), 'id' => 'root',
                 'artifact' => native.fetch('artifact'), 'receipt' => native.fetch('receipt') }]
    output = File.join(@directory, 'development.erxpack')
    result = production.build(entries: entries, root_path: 'system/root', build_kind: 'development',
                              platform: JSON.parse(File.read(File.join(@root, 'config/platforms/qemu-virt.json'))),
                              artifacts: { 'root' => { 'kind' => 'executable', 'entry' => 2 } }.merge(ManifestContextFixture.images),
                              manifest_source: File.binread(File.join(@root, 'config/manifest/qemu-virt-development.txt')),
                              output: output)
    assert_equal 'stopgap', result.fetch('manifest').fetch('mode')
    assert_equal 'declared', result.fetch('manifest').fetch('root_startup')
    bytes = File.binread(output)
    assert_equal "ERXPACK\0".b, bytes.byteslice(0, 8)
    assert_equal bytes.bytesize, @codec.decode_layout('erx_pack_header', bytes).fetch('total_size')
  end
end
