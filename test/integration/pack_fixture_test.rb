# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/pack_root'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/elf_plan'
require_relative '../../tools/lib/erx/toolchain_provenance'

class PackFixtureTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    scratch = File.join(@root, 'build/test')
    FileUtils.mkdir_p(scratch)
    @directory = Dir.mktmpdir('native-pack-', scratch)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    @compiler = ENV.fetch('ERX_CLANG', 'clang')
    @linker = ENV.fetch('ERX_LLD', 'ld.lld')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
  end

  def test_real_native_elf_plan_and_build_receipt_are_reproducible
    tools = Erx::PackTools.build(root: @root, owner_root: @directory, directory: File.join(@directory, 'tools'),
                                 runner: @runner, compiler: @compiler)
    planner = Erx::ElfPlanner.new(helper: tools.fetch('planner'), runner: @runner, codec: @codec)
    first = PackRootFixture.build(root: @root, directory: File.join(@directory, 'first'),
                                  codec: @codec, runner: @runner, compiler: @compiler, linker: @linker)
    second = PackRootFixture.build(root: @root, directory: File.join(@directory, 'second'),
                                   codec: @codec, runner: @runner, compiler: @compiler, linker: @linker)
    assert_equal Digest::SHA256.file(first.fetch('artifact')).hexdigest,
                 Digest::SHA256.file(second.fetch('artifact')).hexdigest
    oracle = @runner.run([ENV.fetch('ERX_READELF', 'llvm-readelf'), '--program-headers', '--wide',
                          first.fetch('artifact')], name: 'read-native-headers', deadline: 30)
    note = File.read(oracle.fetch('log')).lines.find { |line| line.lstrip.start_with?('NOTE ') }
    assert note, 'LLVM oracle did not report the ABI note'
    assert_match(/\sR\s+0x/, note)
    plan = planner.call(first.fetch('artifact'), budget: 1_048_576)
    assert_equal @codec.constant('user_base_min'), plan.fetch('fixed_base')
    assert_equal @codec.constant('page_size'), plan.fetch('base_alignment')
    assert_equal 1, plan.fetch('loads').size
    receipt = Erx::JsonInput.parse(File.binread(first.fetch('receipt')))
    assert_equal first.fetch('sources').size,
                 receipt.fetch('compiles').first.fetch('sources').size
    assert_equal Digest::SHA256.file(first.fetch('artifact')).hexdigest,
                 receipt.fetch('artifact').fetch('sha256')
    resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
    external = Erx::ToolchainProvenance.llvm(root: @root, resource_dir: File.read(resource.fetch('log')).strip)
    resolver = Erx::PackProvenance.new(root: @root, catalog: first.fetch('catalog').merge(second.fetch('catalog')), external: external, runner: @runner)
    first_closure = resolver.resolve(receipt: first.fetch('receipt'), artifact: first.fetch('artifact'),
                                     build_kind: 'development')
    second_closure = resolver.resolve(receipt: second.fetch('receipt'), artifact: second.fetch('artifact'),
                                      build_kind: 'development')
    assert_equal first_closure, second_closure
    assert_equal 11, first_closure.count { |record| record.fetch('path').start_with?('toolchain/') }
    assert_includes resolver.notices(first_closure), 'Apache License'
    helper_receipt = tools.fetch('planner').path + '.receipt.json'
    original_receipt = File.binread(helper_receipt)
    modified = JSON.parse(original_receipt)
    modified['sha256'] = '0' * 64
    File.write(helper_receipt, JSON.generate(modified))
    assert planner.call(first.fetch('artifact'), budget: 1_048_576)
    File.binwrite(helper_receipt, original_receipt)
    modified = JSON.parse(original_receipt)
    modified.fetch('sources').first['sha256'] = '0' * 64
    File.write(helper_receipt, JSON.generate(modified))
    assert planner.call(first.fetch('artifact'), budget: 1_048_576)
  end
end
