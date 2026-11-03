# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'core_archive'
require_relative 'output_directory'
require_relative 'stack_graph'
require_relative 'stack_proof'

module Erx
  # The stack proof as the build runs it on the stopgap
  # (docs/design-stopgap.md, "The stack proof"): it proves the C17 cores'
  # call graph at -O0 and at the level of the cores' archive, -O2, and
  # writes the report. The cores and their flags are the archive's
  # (CoreArchive), and a build that has compiled the archive hands its
  # objects in, so the -O2 proof reads the very objects the kernel links;
  # without them the proof compiles that level itself.
  #
  # The entries are the archive's exported functions, a superset of those
  # the kernel image references, and so a stricter proof. The cores
  # CoreArchive::BOOTSTRAP_SOURCES names are linked into bootstrap and not
  # into the kernel, so they run on no thread block and the report lists
  # them as outside the claim.
  module StackProofRun
    LEVELS = ['-O0', CoreArchive::LEVEL].freeze
    BUDGET = 'kernel/stack_fiasco.txt'
    TARGETS = 'kernel/stack_targets.txt'
    REPORT = 'report.txt'

    module_function

    # Proves both levels over the tree at root and writes the report under
    # output, a directory below project. archive, when given, maps each
    # core source to its object of the archive's level. Returns the
    # report's lines; raises StackProofError, StackGraphError or another
    # Erx::Error on a refusal, which leaves no report behind, so a report on
    # disk is always the current tree's.
    def call(root:, compiler:, runner:, output:, project: root, archive: nil)
      report_path = File.join(OutputDirectory.prepare(root: project, path: output), REPORT)
      FileUtils.rm_f(report_path)
      budget = StackProofInput.budget(read(root, BUDGET), path: BUDGET)
      targets = StackProofInput.targets(read(root, TARGETS), path: TARGETS)
      tools = StackGraph::Tools.beside(compiler)
      cores = CoreArchive.sources(root)
      if archive && archive.keys != cores
        raise StackProofError, 'stack proof: the archive objects are not the cores of this tree'
      end

      lines = Dir.mktmpdir('erx-stack-proof-') do |scratch|
        LEVELS.flat_map do |level|
          objects = level_objects(level, archive: archive, root: root, cores: cores, compiler: compiler,
                                  runner: runner, scratch: scratch)
          graph = StackGraph.extract(inputs: objects.values.map { |object| StackGraph::Input.beside(object) },
                                     tools: tools, runner: runner)
          StackProof.prove(graph: graph, entries: entries(graph), budget: budget, targets: targets,
                           level: level).lines
        end
      end
      bootstrap = CoreArchive::BOOTSTRAP_SOURCES.map { |source| "outside the claim: #{source}, linked into bootstrap" }
      report = [*lines, *bootstrap]
      write(report, path: report_path)
      report
    end

    # The archive's own objects at its level; otherwise a fresh compile.
    def level_objects(level, archive:, root:, cores:, compiler:, runner:, scratch:)
      return archive if archive && level == CoreArchive::LEVEL

      directory = File.join(scratch, level.delete('-'))
      FileUtils.mkdir_p(directory)
      CoreArchive.compile(root: root, sources: cores, level: level, compiler: compiler, runner: runner,
                          directory: directory)
    end

    # Every object of the graph is a core, so every exported function is
    # an entry.
    def entries(graph)
      graph.functions.each_value.select { |function| function.id.global? }.map(&:id)
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

    private_class_method :level_objects, :entries, :read, :write
  end
end
