# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'output_directory'
require_relative 'stack_graph'
require_relative 'stack_proof'

module Erx
  # The stack proof as the build runs it on the stopgap
  # (docs/design-stopgap.md, "The stack proof"): it compiles the C17 cores
  # for AArch64 at -O0 and at -O2 with the flags of the cores' archive,
  # extracts each level's call graph, proves it, and writes the report.
  #
  # The entries are the cores' exported functions, a superset of those the
  # kernel image references, and so a stricter proof. The one exception is
  # BOOTSTRAP_SOURCES, which the stopgap links into bootstrap and not into
  # the kernel, so they run on no thread block and the report lists them as
  # outside the claim. SUPPORT_SOURCES are compiled into the graph so that
  # a core may call them, but their functions are not entries.
  module StackProofRun
    LEVELS = %w[-O0 -O2].freeze
    CORE_PATTERNS = %w[kernel/core/*.c kernel/sched/*.c kernel/generated/*.c].freeze
    BOOTSTRAP_SOURCES = %w[kernel/core/pack.c].freeze
    SUPPORT_SOURCES = %w[liberx/generated/abi_reader.c].freeze
    FLAGS = %w[-std=c17 -Wall -Wextra -Werror -pedantic --target=aarch64-none-elf -ffreestanding
               -mgeneral-regs-only -mno-outline-atomics -fstack-usage -ffunction-sections
               -I include -I kernel/generated].freeze
    BUDGET = 'kernel/stack_fiasco.txt'
    TARGETS = 'kernel/stack_targets.txt'
    REPORT = 'report.txt'

    module_function

    # Proves both levels and writes the report under output. Returns the
    # report's lines; raises StackProofError, StackGraphError or another
    # Erx::Error on a refusal, which leaves no report behind, so a report on
    # disk is always the current tree's.
    def call(root:, compiler:, runner:, output:)
      report_path = File.join(OutputDirectory.prepare(root: root, path: output), REPORT)
      FileUtils.rm_f(report_path)
      budget = StackProofInput.budget(read(root, BUDGET), path: BUDGET)
      targets = StackProofInput.targets(read(root, TARGETS), path: TARGETS)
      tools = StackGraph::Tools.beside(compiler)
      cores = core_sources(root)
      lines = Dir.mktmpdir('erx-stack-proof-') do |scratch|
        LEVELS.flat_map do |level|
          objects = (cores + SUPPORT_SOURCES).to_h do |source|
            [source, compile(source, level: level, root: root, compiler: compiler, runner: runner, scratch: scratch)]
          end
          graph = StackGraph.extract(inputs: objects.values.map { |object| StackGraph::Input.beside(object) },
                                     tools: tools, runner: runner)
          StackProof.prove(graph: graph, entries: entries(graph, objects.values_at(*cores)), budget: budget,
                           targets: targets, level: level).lines
        end
      end
      report = [*lines, *BOOTSTRAP_SOURCES.map { |source| "outside the claim: #{source}, linked into bootstrap" }]
      write(report, path: report_path)
      report
    end

    # Every C17 core but the bootstrap ones, sorted so that the graph and
    # the report come out the same on every run.
    def core_sources(root)
      found = CORE_PATTERNS.flat_map { |pattern| Dir.glob(pattern, base: root) }.sort
      missing = BOOTSTRAP_SOURCES - found
      raise StackProofError, "stack proof: bootstrap source #{missing.first} is missing" unless missing.empty?

      cores = found - BOOTSTRAP_SOURCES
      raise StackProofError, 'stack proof: no C17 core sources' if cores.empty?

      cores
    end

    def entries(graph, core_objects)
      graph.functions.each_value.select { |function| function.id.global? && core_objects.include?(function.object) }
           .map(&:id)
    end

    # Each object goes to a fresh directory, so no .su file of an earlier
    # build can stand in for its frames. The compile runs from the root
    # with relative paths, so the frames' source positions in the report
    # name the tree's files and not this host's checkout.
    def compile(source, level:, root:, compiler:, runner:, scratch:)
      object = File.join(scratch, level.delete('-'), source.delete_suffix('.c').tr('/', '_') + '.o')
      FileUtils.mkdir_p(File.dirname(object))
      runner.run([compiler, *FLAGS, level, '-c', source, '-o', object],
                 name: 'stack-proof-compile', deadline: 120, chdir: root)
      object
    end

    def read(root, relative) = BoundedFile.read(File.join(root, relative), maximum: StackProofInput::MAX_FILE_BYTES)

    # Through a fresh temporary file renamed into place, so a link planted
    # at the report's name redirects nothing and no reader sees half a
    # report.
    def write(report, path:)
      temporary = "#{path}.tmp-#{Process.pid}"
      created = false
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
          created = true
          file.write(report.join("\n") + "\n")
        end
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if created && File.file?(temporary) && !File.symlink?(temporary)
      end
    end

    private_class_method :core_sources, :entries, :compile, :read, :write
  end
end
