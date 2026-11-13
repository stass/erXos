# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/elf_fixture'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/elf_plan'
require_relative '../fixtures/generated_tree'

class PackToolRecipeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze

  def copy_project(directory)
    files = (Erx::PackToolRecipe::PROGRAMS.values.flat_map { |_name, cores, main| [*cores, main] } +
             Erx::PackToolRecipe::COMMON_SOURCES + Erx::PackToolRecipe::RECIPE_SOURCES + ['tools/host/input.h'] +
             Dir.glob(%w[include/erx/**/*.h build/gen/include/erx/**/*.h kernel/crypto/blake3/*.h littlefs/*.h
                       otp/erts/emulator/nifs/erxos/erx_littlefs.h liberx/backend/core/*.h], base: ROOT)).uniq
    files.each do |relative|
      target = File.join(directory, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(ROOT, relative), target)
    end
  end

  def test_owned_helper_keeps_complete_inputs_when_audit_files_are_forged
    Dir.mktmpdir('owned-parser-') do |directory|
      project = File.join(directory, 'project')
      copy_project(project)
      header = File.join(project, 'include/erx/fixture/nested.h')
      FileUtils.mkdir_p(File.dirname(header))
      File.write(header, "#define ERX_RECIPE_TEST_VALUE 1\n")
      File.open(File.join(project, 'include/erx/elf_plan.h'), 'a') { |file| file.write("\n#include \"fixture/nested.h\"\n") }
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      tools = Erx::PackTools.build(root: project, owner_root: directory,
                                   directory: File.join(directory, 'tools'), runner: runner)
      helper = tools.fetch('planner')
      codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
      planner = Erx::ElfPlanner.new(helper: helper, runner: runner, codec: codec)
      input = File.join(directory, 'fixture.elf')
      File.binwrite(input, ElfFixture.valid)
      assert planner.call(input, budget: 1_048_576)
      assert helper.frozen?
      assert_raises(NoMethodError) { Erx::PackTools::Helper.new }
      assert_raises(Erx::Error) { Erx::ElfPlanner.new(helper: helper.path, runner: runner, codec: codec) }

      # Sidecars cannot replace the in-process expected set, including a header
      # omitted from every forged .d record or a duplicated/reduced source list.
      record_path = helper.path + '.receipt.json'
      record = JSON.parse(File.binread(record_path))
      record['sources'] = [record.fetch('sources').first] * 2
      record['recipe_sha256'] = '0' * 64
      record.fetch('dependencies').each_with_index do |item, index|
        path = File.join(helper.path + '.deps', item.fetch('path'))
        source = Erx::PackToolRecipe.plan(root: project, tool: 'planner', sanitizers: []).fetch('compile_sources')[index]
        File.write(path, "#{File.join(helper.path + '.objects', "#{index}.o")}: #{File.join(project, source)}\n")
        item['sha256'] = Digest::SHA256.file(path).hexdigest
      end
      File.write(record_path, JSON.generate(record))
      assert planner.call(input, budget: 1_048_576)

      original = File.binread(header)
      File.write(header, "#define ERX_RECIPE_TEST_VALUE 2\n")
      assert_raises(Erx::Error) { planner.call(input, budget: 1_048_576) }
      File.binwrite(header, original)
      File.unlink(header)
      assert_raises(Erx::Error) { planner.call(input, budget: 1_048_576) }
      File.binwrite(header, original)
      parser = File.join(project, 'liberx/elf_plan.c')
      parser_bytes = File.binread(parser)
      File.open(parser, 'a') { |file| file.write("\n/* changed parser input */\n") }
      assert_raises(Erx::Error) { planner.call(input, budget: 1_048_576) }
      File.binwrite(parser, parser_bytes)
      binary = File.binread(helper.path)
      File.binwrite(helper.path, 'changed executable')
      assert_raises(Erx::Error) { planner.call(input, budget: 1_048_576) }
      File.binwrite(helper.path, binary)
      assert planner.call(input, budget: 1_048_576)
    end
  end

  # Agent worktrees live under .claude/worktrees inside the main checkout,
  # and Codex worktrees under a .codex directory; only the components below
  # the project root decide whether a project input is private state.
  def test_checkout_below_agent_state_builds_its_tools
    Dir.mktmpdir('nested-parser-') do |directory|
      project = File.join(directory, '.codex/worktrees/p/.claude/worktrees/x')
      copy_project(project)
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      tools = Erx::PackTools.build(root: project, owner_root: directory,
                                   directory: File.join(directory, 'tools'), runner: runner)
      codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
      planner = Erx::ElfPlanner.new(helper: tools.fetch('planner'), runner: runner, codec: codec)
      input = File.join(directory, 'fixture.elf')
      File.binwrite(input, ElfFixture.valid)
      assert planner.call(input, budget: 1_048_576)
    end
  end

  def test_recipe_of_a_checkout_below_agent_state_reads_its_sources
    %w[.claude/worktrees/x .codex/worktrees/x].each do |parent|
      Dir.mktmpdir('nested-recipe-') do |directory|
        project = File.join(directory, parent)
        copy_project(project)
        assert_equal 'elf-plan', Erx::PackToolRecipe.plan(root: project, tool: 'planner', sanitizers: []).fetch('name')
      end
    end
  end

  def test_private_state_inside_the_project_is_never_a_source
    Dir.mktmpdir('private-recipe-') do |directory|
      project = File.join(directory, '.claude/worktrees/x')
      %w[.claude/settings.h .git/config.h .codex/state.h include/.ssh/key.h].each do |relative|
        path = File.join(project, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#define ERX_PRIVATE 1\n")
        error = assert_raises(Erx::Error) { Erx::PackToolRecipe.source_path(project, relative) }
        assert_match(/outside the authorized project/, error.message)
      end
      File.write(File.join(project, 'public.h'), "#define ERX_PUBLIC 1\n")
      assert_equal File.realpath(File.join(project, 'public.h')), Erx::PackToolRecipe.source_path(project, 'public.h')
    end
  end

  def test_build_refuses_a_header_from_private_state_inside_the_project
    Dir.mktmpdir('private-parser-') do |directory|
      project = File.join(directory, 'project')
      copy_project(project)
      private_header = File.join(project, '.claude/leak.h')
      FileUtils.mkdir_p(File.dirname(private_header))
      File.write(private_header, "#define ERX_RECIPE_LEAK 1\n")
      File.open(File.join(project, 'include/erx/elf_plan.h'), 'a') { |file| file.write("\n#include \"../../.claude/leak.h\"\n") }
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      error = assert_raises(Erx::Error) do
        Erx::PackTools.build(root: project, owner_root: directory, directory: File.join(directory, 'tools'), runner: runner)
      end
      assert_match(/outside the authorized project/, error.message)
    end
  end

  # Writes a dependency probe that names the given compiler metadata, as a
  # compiler driver lists implicit inputs such as SDKSettings.json.
  class MetadataRunner
    def initialize(metadata:, log:)
      @metadata = metadata
      @log = log
    end

    def run(argv, name:, deadline:)
      return { 'log' => @log } unless argv.include?('-MM')

      dependency = argv.fetch(argv.index('-MF') + 1)
      object = argv.fetch(argv.index('-MQ') + 1)
      File.write(dependency, "#{object}: #{argv.last} #{@metadata}\n")
      {}
    end
  end

  def compiler_profile_with(metadata, directory:, project:)
    FileUtils.mkdir_p(File.dirname(metadata))
    File.write(metadata, "{}\n")
    log = File.join(directory, 'version.log')
    File.write(log, "clang version 0\n")
    Erx::PackToolRecipe.compiler_profile(compiler: 'clang', runner: MetadataRunner.new(metadata: metadata, log: log),
                                         directory: File.join(directory, 'profile'), owner_root: directory,
                                         root: project)
  end

  def test_compiler_metadata_is_judged_below_the_project_root
    Dir.mktmpdir('metadata-recipe-') do |directory|
      project = File.join(directory, '.codex/worktrees/x')
      inside = File.join(project, 'sdk/SDKSettings.json')
      profile = compiler_profile_with(inside, directory: directory, project: project)
      assert_equal [File.realpath(inside)], profile.fetch('inputs').map { |input| input.fetch('path') }
      [File.join(project, '.git/SDKSettings.json'), File.join(directory, 'home/.ssh/SDKSettings.json')].each do |path|
        error = assert_raises(Erx::Error) { compiler_profile_with(path, directory: directory, project: project) }
        assert_equal 'compiler metadata names private state', error.message
      end
    end
  end
end
