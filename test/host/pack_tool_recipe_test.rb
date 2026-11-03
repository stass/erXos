# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/elf_fixture'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/elf_plan'

class PackToolRecipeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze

  def copy_project(directory)
    files = (Erx::PackToolRecipe::PROGRAMS.values.flat_map { |_name, core, main| [core, main] } +
             Erx::PackToolRecipe::COMMON_SOURCES + Erx::PackToolRecipe::RECIPE_SOURCES + ['tools/host/input.h'] +
             Dir.glob(File.join(ROOT, 'include/erx/**/*.h')).map { |path| path.delete_prefix(ROOT + '/') }).uniq
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
end
