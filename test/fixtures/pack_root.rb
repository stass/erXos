# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'fileutils'
require_relative '../../tools/lib/erx/pack_provenance'
require_relative '../../tools/lib/erx/output_directory'
require_relative '../../tools/lib/erx/llvm_version'
require_relative 'generated_tree'

# A real freestanding AArch64 ELF, with compiler dependency and linker map
# receipts. No libc or compiler runtime enters this fixture's link closure.
module PackRootFixture
  module_function

  def build(root:, directory:, codec:, runner:, compiler:, linker:)
    directory = Erx::OutputDirectory.prepare(root: root, path: directory)
    source = File.join(root, 'test/fixtures/pack_root/root.c')
    template = File.join(root, 'test/fixtures/pack_root/aarch64.ld.in')
    script = File.join(directory, 'root.ld')
    template_input = reference(template, root)
    values = { '@ERX_BASE@' => codec.constant('user_base_min'),
               '@ERX_RX@' => codec.constant('elf_pf_r') | codec.constant('elf_pf_x'),
               '@ERX_R@' => codec.constant('elf_pf_r') }
    File.write(script, File.read(template).gsub(/@ERX_[A-Z]+@/) { |name| values.fetch(name).to_s })
    object = File.join(directory, 'root.o')
    dependency = File.join(directory, 'root.d')
    artifact = File.join(directory, 'root.elf')
    map = File.join(directory, 'root.map')
    runner.run([compiler, '--target=aarch64-none-elf', '-std=c17', '-ffreestanding',
                '-M', '-MF', dependency, '-MT', object, *Erx::Generated.include_flags(root: root),
                '-I', File.join(root, 'include'), source],
               name: 'scan-pack-root', deadline: 60, chdir: root)
    _targets, sources = Erx::PackProvenance.dependencies(File.binread(dependency))
    inputs = sources.map { |path| reference(File.expand_path(path, root), root) }
    script_input = reference(script, root)
    runner.run([compiler, '--target=aarch64-none-elf', '-std=c17', '-Wall', '-Wextra', '-Werror',
                '-pedantic', '-ffreestanding', '-fno-stack-protector', '-fno-unwind-tables',
                '-fno-asynchronous-unwind-tables', '-O2', '-MD', '-MF', dependency,
                *Erx::Generated.include_flags(root: root),
                '-I', File.join(root, 'include'), '-c', source, '-o', object],
               name: 'compile-pack-root', deadline: 60, chdir: root)
    runner.run([linker, '--build-id=none',
                '-z', "max-page-size=#{codec.constant('page_size')}", '-T', script,
                '-Map', map, object, '-o', artifact],
               name: 'link-pack-root', deadline: 60, chdir: root)
    _targets, after_sources = Erx::PackProvenance.dependencies(File.binread(dependency))
    after_inputs = after_sources.map { |path| reference(File.expand_path(path, root), root) }
    unless inputs == after_inputs && script_input == reference(script, root) &&
           template_input == reference(template, root)
      raise Erx::Error, 'fixture sources changed during compilation'
    end
    receipt = { 'version' => 1, 'kind' => 'linked', 'artifact' => reference(artifact, root),
                'linker_map' => reference(map, root).merge('format' => 'lld', 'directory' => '.'),
                'compiles' => [{ 'object' => reference(object, root),
                                 'dependency' => reference(dependency, root), 'directory' => '.',
                                 'sources' => inputs }],
                'archives' => [], 'inputs' => [script_input, template_input],
                'toolchain' => Erx::LlvmVersion.toolchain(compiler: compiler, linker: linker, runner: runner,
                                                          name: 'pack-root') }
    receipt_path = File.join(directory, 'root.receipt.json')
    File.write(receipt_path, JSON.pretty_generate(receipt) + "\n")
    paths = [artifact, object, dependency, map, receipt_path, script, template, *sources.map { |path| File.expand_path(path, root) }]
    catalog = Erx::BuildInputs.pack(root: root, paths: paths)
    (inputs + [script_input, template_input]).each do |reference|
      catalog.authorize(File.expand_path(reference.fetch('path'), root), expected: reference.fetch('sha256'))
    end
    { 'artifact' => artifact, 'receipt' => receipt_path, 'sources' => sources, 'catalog' => catalog }.freeze
  end

  def reference(path, root)
    public_path = path.start_with?(root + '/') ? path.delete_prefix(root + '/') : path
    { 'path' => public_path, 'sha256' => Digest::SHA256.file(path).hexdigest }
  end
end
