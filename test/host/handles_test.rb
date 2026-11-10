# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# The object records and handle tables on the host: the driver test/fixtures/handles_driver.c
# replays every sequence of creates, dups, closes, destroys and the generation hook up to a
# fixed depth against a model of serials, then the limit, the pool running dry and the
# refusals. Each mutant below seeds a bug the core could have, and the driver must name it.
# liberx/backend/core/handles.c is the core under test.
class HandlesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = %w[liberx/backend/core/handles.c liberx/backend/core/grow_table.c].freeze
  DRIVER = 'test/fixtures/handles_driver.c'

  # name => [original, replacement, the driver's diagnostic]; each edits one place in handles.c.
  MUTANTS = {
    'the generation compare removed' => ['record->generation == entry->generation', 'true',
                                       'a handle answers otherwise than the model'],
    'the retire removed' => ["\tif (record->generation == UINT32_MAX) {\n", "\tif (0) {\n",
                           'a handle answers otherwise than the model'],
    'the limit not checked' => ["\t\tif (usable >= handles->limit)\n\t\t\treturn (ERX_ELIMIT);\n", '',
                              'past the limit was given'],
    'a stale close counted' => ["\tif (entry_live(objects, entry)) {\n", "\tif (entry->object != 0) {\n",
                              "a close's last reference misjudged"],
    'a mapping ignored' => ["\treturn (record->handles == 0 && record->mappings == 0 && record->kept == 0);\n",
                          "\treturn (record->handles == 0 && record->kept == 0);\n", 'a mapped object went with its last handle'],
    'a keep ignored' => ["\treturn (record->handles == 0 && record->mappings == 0 && record->kept == 0);\n",
                       "\treturn (record->handles == 0 && record->mappings == 0);\n", 'a kept record went unreferenced'],
    'a freed record taken while retired' => ["\twhile (found < capacity && erx_backend_object_at(objects, found)->kind != ERX_BACKEND_OBJECT_FREE)\n",
                                           "\twhile (found < capacity && erx_backend_object_at(objects, found)->kind > ERX_BACKEND_OBJECT_RETIRED)\n",
                                           'a handle answers otherwise than the model']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-handles-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_the_core_agrees_with_the_model
    assert_match(/^ok: [1-9][0-9]* checks$/, run_driver(build(File.join(ROOT, CORE.first), name: 'driver')))
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_the_driver_catches_#{name.tr(' ', '_')}") do
      assert_includes driver_failure(mutant(name, original, replacement)), diagnostic
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(core, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-D_DARWIN_C_SOURCE',
                 '-D_GNU_SOURCE', *@sanitizer_flags, *Erx::Generated.include_flags(root: ROOT),
                 '-I', File.join(ROOT, 'include'), '-I', ROOT, core, File.join(ROOT, CORE.last), File.join(ROOT, DRIVER),
                 '-o', output],
                name: "compile-#{name.tr(' ', '-')}", deadline: 60)
    output
  end

  def run_driver(driver)
    File.read(@runner.run([driver], name: 'run-driver', deadline: 120).fetch('log'))
  end

  # What the driver said as it failed; a driver that passes fails the test.
  def driver_failure(driver)
    output = run_driver(driver)
    flunk("the driver missed this: #{output}")
  rescue Erx::CommandError => e
    File.read(e.result.fetch('log'))
  end

  def mutant(name, original, replacement)
    source = File.read(File.join(ROOT, CORE.first))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
    path = File.join(@directory, "#{name.tr(' ', '-')}.c")
    File.write(path, source.sub(original) { replacement })
    build(path, name: "mutant-#{name}")
  end
end
