# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'runner'
require_relative 'bounded_file'
require_relative 'pack_provenance'
require_relative 'output_directory'
require_relative 'private_state'

module Erx
  # Producer and verifier share the complete project-input recipe. A record
  # cannot choose a smaller source set or invent another compilation profile.
  module PackToolRecipe
    # BLAKE3's portable C, the same sources the kernel builds; the host tools
    # could take its SIMD code too, which is not imported
    # (docs/todo-performance.md).
    BLAKE3 = %w[kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c].freeze
    # Each program: its binary's name, the cores it links and its main.
    PROGRAMS = { 'checker' => ['pack-check', ['kernel/core/pack.c', *BLAKE3].freeze, 'tools/host/pack_check.c'].freeze,
                 'hasher' => ['pack-hash', BLAKE3, 'tools/host/pack_hash.c'].freeze,
                 'planner' => ['elf-plan', ['liberx/elf_plan.c'].freeze, 'tools/host/elf_plan.c'].freeze,
                 'domains' => ['dom-plan', %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/system/dom_boot_view.c liberx/erx_lane.c].freeze,
                               'tools/host/dom_plan.c'].freeze }.freeze
    COMMON_SOURCES = %w[build/gen/liberx/generated/abi_reader.c tools/host/input.c].freeze
    RECIPE_SOURCES = %w[tools/lib/erx/pack_tool_recipe.rb tools/lib/erx/pack_tools.rb tools/lib/erx/elf_plan.rb
                        tools/lib/erx/dom_planner.rb].freeze
    # The include directories every program compiles with, from the root.
    INCLUDES = %w[build/gen build/gen/include include kernel/crypto].freeze
    FLAGS = %w[-std=c17 -Wall -Wextra -Werror -pedantic -O1 -g].freeze
    module_function

    def plan(root:, tool:, sanitizers:, dependencies: [], compiler_profile: nil)
      unless PROGRAMS.key?(tool) && sanitizers.is_a?(Array) && sanitizers.uniq == sanitizers &&
             (sanitizers - %w[address undefined]).empty?
        raise Error, 'unknown host parser recipe'
      end
      name, cores, main = PROGRAMS.fetch(tool)
      compile_sources = [*cores, *COMMON_SOURCES, main]
      inputs = (compile_sources + ['tools/host/input.h'] + RECIPE_SOURCES + dependencies).uniq.sort.freeze
      flags = FLAGS + (sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer'])
      recipe_hashes = RECIPE_SOURCES.to_h { |path| [path, Digest::SHA256.file(source_path(root, path)).hexdigest] }
      identity = Digest::SHA256.hexdigest(JSON.generate('version' => 1, 'tool' => tool, 'sources' => inputs,
                                                       'compile_sources' => compile_sources, 'flags' => flags,
                                                       'recipe_sources' => recipe_hashes, 'compiler' => compiler_profile))
      { 'name' => name, 'inputs' => inputs, 'compile_sources' => compile_sources.freeze,
        'flags' => flags.freeze, 'sha256' => identity.freeze }.freeze
    end

    # The builder reads its compiler's actual dependency output. These audit
    # records are never loaded as executable authority by a later consumer.
    def read_dependencies(root:, program:, compile_sources:, compiler_profile:)
      inputs = []
      references = compile_sources.each_with_index.map do |source, index|
        path = File.join(program + '.deps', "#{index}.d")
        canonical = File.realpath(path)
        unless canonical.start_with?(File.realpath(File.dirname(program)) + '/') && !File.symlink?(program + '.deps')
          raise Error, 'host parser dependency record escapes its owned build directory'
        end
        bytes = BoundedFile.read(canonical, maximum: 1024 * 1024)
        hash = Digest::SHA256.hexdigest(bytes)
        record = { 'path' => "#{index}.d", 'sha256' => hash }
        targets, prerequisites = PackProvenance.dependencies(bytes)
        object = File.join(program + '.objects', "#{index}.o")
        unless targets.any? { |target| File.expand_path(target, root) == File.expand_path(object) }
          raise Error, 'host parser dependency target differs from its recipe'
        end
        paths = prerequisites.map do |input|
          resolved = File.realpath(File.expand_path(input, root))
          next if compiler_profile.fetch('inputs').any? { |file| file.fetch('path') == resolved }
          source_path(root, resolved)
          expanded = File.expand_path(input, root)
          unless expanded.start_with?(File.realpath(root) + '/')
            raise Error, 'project compiler input uses an undeclared outside alias'
          end
          expanded.delete_prefix(File.realpath(root) + '/')
        end.compact
        raise Error, 'host parser dependency record omits its source' unless paths.include?(source)
        inputs.concat(paths)
        record.freeze
      end
      { 'inputs' => inputs.uniq.sort.freeze, 'records' => references.freeze }.freeze
    end

    # The configured compiler, not the receipt, determines implicit inputs such
    # as Darwin SDKSettings.json. An empty source isolates those driver inputs
    # from project includes. Their exact bounded bytes are recorded separately.
    # None may lie in private state: below the project root for a file inside
    # the project, anywhere on its path for one outside (PrivateState.inside?).
    def compiler_profile(compiler:, runner:, directory:, owner_root:, root:)
      raise Error, 'host parser verification needs a command runner' unless runner.respond_to?(:run)
      directory = OutputDirectory.prepare(root: owner_root, path: directory)
      Dir.mktmpdir('.compiler-profile-', directory) do |temporary|
        source = File.join(temporary, 'probe.c')
        dependency = File.join(temporary, 'probe.d')
        object = File.join(temporary, 'probe.o')
        File.write(source, "int erx_compiler_dependency_probe;\n")
        runner.run([compiler, '-std=c17', '-MM', '-MF', dependency, '-MQ', object, source],
                   name: 'probe-parser-compiler', deadline: 30)
        targets, inputs = PackProvenance.dependencies(BoundedFile.read(dependency, maximum: 1024 * 1024))
        unless targets == [object] && inputs.include?(source)
          raise Error, 'configured compiler returned an unsupported dependency probe'
        end
        references = inputs.reject { |path| path == source }.map do |path|
          canonical = File.realpath(path)
          raise Error, 'compiler metadata names private state' if PrivateState.inside?(canonical, project_root: root)
          { 'path' => canonical.freeze,
            'sha256' => Digest::SHA256.hexdigest(BoundedFile.read(canonical, maximum: 1024 * 1024)).freeze }.freeze
        end.sort_by { |file| file.fetch('path') }.freeze
        version = runner.run([compiler, '--version'], name: 'parser-compiler-version', deadline: 30)
        version_bytes = BoundedFile.read(version.fetch('log'), maximum: 65_536)
        version_text = version_bytes.dup.force_encoding(Encoding::UTF_8)
        raise Error, 'compiler version output is not UTF-8' unless version_text.valid_encoding?
        { 'command' => compiler.dup.freeze, 'inputs' => references,
          'version' => version_text.freeze,
          'version_sha256' => Digest::SHA256.hexdigest(version_bytes).freeze }.freeze
      end
    end

    # A recipe source is a canonical path inside the project and outside its
    # private state.
    def source_path(root, relative)
      path = File.realpath(File.expand_path(relative, root))
      unless path.start_with?(File.realpath(root) + '/') && !PrivateState.inside?(path, project_root: root)
        raise Error, "host parser recipe source is outside the authorized project: #{Terminal.escape(path)}"
      end
      path
    end
  end
end
