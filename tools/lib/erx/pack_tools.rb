# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require_relative 'runner'
require_relative 'pack_tool_recipe'
require_relative 'build_inputs'
require_relative 'output_directory'

module Erx
  module PackTools
    # An audit sidecar is not executable authority. Only this builder creates
    # handles, retaining its own complete input observations and binary identity.
    class Helper
      attr_reader :path, :root, :tool, :compiler_profile, :recipe_sha256

      def initialize(path:, root:, tool:, inputs:, compiler_profile:, recipe_sha256:)
        @path = path.dup.freeze
        @root = root.dup.freeze
        @tool = tool.dup.freeze
        @inputs = inputs
        @compiler_profile = compiler_profile
        @recipe_sha256 = recipe_sha256
        freeze
      end
      private_class_method :new

      # Verification and execution share one funnel; callers never remember a
      # separate path-check/exec sequence or choose a receipt's expected values.
      def run(arguments, runner:, name:, deadline:)
        @inputs.verify_all
        runner.run([@path, *arguments], name: name, deadline: deadline)
      end
    end
    module_function

    def build(root:, owner_root:, directory:, runner:, compiler: 'clang', sanitizers: [], tools: PackToolRecipe::PROGRAMS.keys)
      raise Error, 'invalid host parser sanitizer' unless (sanitizers - %w[address undefined]).empty?
      raise Error, 'unknown host parser recipe' unless tools.is_a?(Array) && !tools.empty? && (tools - PackToolRecipe::PROGRAMS.keys).empty?
      root = File.realpath(root)
      directory = OutputDirectory.prepare(root: owner_root, path: directory)
      compiler_profile = PackToolRecipe.compiler_profile(compiler: compiler, runner: runner, directory: directory,
                                                         owner_root: owner_root, root: root)
      tools.uniq.to_h do |key|
        recipe = PackToolRecipe.plan(root: root, tool: key, sanitizers: sanitizers, compiler_profile: compiler_profile)
        name = recipe.fetch('name')
        path = File.join(directory, name)
        OutputDirectory.prepare(root: owner_root, path: path + '.deps')
        OutputDirectory.prepare(root: owner_root, path: path + '.objects')
        recipe.fetch('compile_sources').each_with_index do |source, index|
          runner.run([compiler, *recipe.fetch('flags'), *PackToolRecipe::INCLUDES.flat_map { |directory| ['-I', File.join(root, directory)] },
                      '-MM', '-MF', File.join(path + '.deps', "#{index}.d"),
                      '-MQ', File.join(path + '.objects', "#{index}.o"), File.join(root, source)],
                     name: "scan-#{name}-#{index}", deadline: 90, chdir: root)
        end
        scanned = PackToolRecipe.read_dependencies(root: root, program: path, compile_sources: recipe.fetch('compile_sources'), compiler_profile: compiler_profile)
        recipe = PackToolRecipe.plan(root: root, tool: key, sanitizers: sanitizers, dependencies: scanned.fetch('inputs'), compiler_profile: compiler_profile)
        input_paths = recipe.fetch('inputs').map { |input| File.join(root, input) } +
                      compiler_profile.fetch('inputs').map { |input| input.fetch('path') }
        before = BuildInputs.capture(root: root, paths: input_paths)
        sources = recipe.fetch('inputs').map do |input|
          observed = before.entry(File.join(root, input))
          { 'path' => input, 'sha256' => observed.fetch('sha256'), 'size' => observed.fetch('size') }.freeze
        end
        objects = recipe.fetch('compile_sources').each_with_index.map do |source, index|
          object = File.join(path + '.objects', "#{index}.o")
          runner.run([compiler, *recipe.fetch('flags'), *PackToolRecipe::INCLUDES.flat_map { |directory| ['-I', File.join(root, directory)] },
                      '-MMD', '-MF', File.join(path + '.deps', "#{index}.d"), '-MQ', object,
                      '-c', File.join(root, source), '-o', object],
                     name: "compile-#{name}-#{index}", deadline: 90, chdir: root)
          object
        end
        after = PackToolRecipe.read_dependencies(root: root, program: path, compile_sources: recipe.fetch('compile_sources'), compiler_profile: compiler_profile)
        unless after == scanned
          raise Error, 'host parser dependency set changed during compilation'
        end
        link_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}"]
        runner.run([compiler, *link_flags, *objects, '-o', path], name: "link-#{name}", deadline: 90)
        before.verify_all
        compiler_profile.fetch('inputs').each do |input|
          raise Error, 'compiler metadata changed during compilation' unless before.entry(input.fetch('path')).fetch('sha256') == input.fetch('sha256')
        end
        inputs = before.merge(BuildInputs.capture(root: root, paths: [path]))
        receipt = { 'version' => 1, 'tool' => key, 'sanitizers' => sanitizers,
                    'compiler_profile' => compiler_profile,
                    'recipe_sha256' => recipe.fetch('sha256'),
                    'sha256' => Digest::SHA256.file(path).hexdigest, 'sources' => sources,
                    'dependencies' => after.fetch('records') }
        File.write(path + '.receipt.json', JSON.generate(receipt, ascii_only: true) + "\n")
        helper = Helper.send(:new, path: path, root: root, tool: key, inputs: inputs,
                             compiler_profile: compiler_profile, recipe_sha256: recipe.fetch('sha256'))
        [key, helper]
      end.freeze
    end
  end
end
