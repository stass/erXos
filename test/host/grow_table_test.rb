# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# The growable table's core on the host: the driver test/fixtures/grow_table_driver.c
# grows tables of several record sizes to their limit, runs the page source dry at
# every step of a grow, and checks moves against memmove. Each mutant below seeds a
# bug the core could have, and the driver must name it, which shows the driver
# reaches that code. liberx/backend/core/grow_table.c is the core under test.
class GrowTableTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/core/grow_table.c'
  DRIVER = 'test/fixtures/grow_table_driver.c'

  # name => [original, replacement, the driver's diagnostic]; each edits one place.
  MUTANTS = {
    'a grown page not zeroed' => ["\tbzero((void *)page, ERX_PAGE_SIZE);\n\ttable->directory[table->pages++] = page;\n",
                                  "\ttable->directory[table->pages++] = page;\n", 'a new record does not read zero'],
    'the limit not checked' => ["\tif (records > erx_backend_grow_table_limit(table))\n\t\treturn (ERX_ENOMEM);\n", '',
                                'room past the limit was given'],
    'a refused first grow keeps the directory' => ["\t\tif (table->pages == 0) {\n", "\t\tif (0) {\n",
                                                   'a refused first grow kept a page'],
    'a refusal not reported' => ["\t\tif (table_grow(table) != ERX_OK)\n\t\t\treturn (ERX_ENOMEM);\n",
                                 "\t\tif (table_grow(table) != ERX_OK)\n\t\t\treturn (ERX_OK);\n",
                                 'a grow past the source passed'],
    'a record past the capacity found' => ["\tif (index >= erx_backend_grow_table_capacity(table))\n",
                                           "\tif (index > erx_backend_grow_table_capacity(table))\n",
                                           "a record read outside the table"],
    'an overlapping move in the wrong direction' => ["\tif (to < from)\n", "\tif (to > from)\n",
                                                     'a move disagrees with memmove'],
    'clearing keeps the directory' => ["\tif (table->directory != NULL)\n\t\tpages->give((uintptr_t)table->directory);\n", '',
                                       'clearing left pages']
  }.freeze
  MEMORY_ERRORS = ['the limit not checked', 'a record past the capacity found'].freeze

  def setup
    @directory = Dir.mktmpdir('erx-grow-table-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_the_core_agrees_with_the_model
    assert_match(/^ok: [1-9][0-9]* checks$/, run_driver(build(File.join(ROOT, CORE), name: 'driver')))
  end

  MUTANTS.each do |name, (original, replacement, diagnostic)|
    define_method("test_the_driver_catches_#{name.tr(' ', '_')}") do
      assert_named driver_failure(mutant(name, original, replacement)), name, diagnostic
    end
  end

  private

  # Under a sanitizer, a mutant whose bug is a memory error is named first by the
  # sanitizer's report, which counts as the driver naming it.
  SANITIZER_REPORT = /AddressSanitizer|runtime error:/

  def assert_named(output, name, diagnostic)
    return if !@sanitizer_flags.empty? && MEMORY_ERRORS.include?(name) && output.match?(SANITIZER_REPORT)

    assert_includes output, diagnostic
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(core, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-D_DARWIN_C_SOURCE',
                 '-D_GNU_SOURCE', *@sanitizer_flags, *Erx::Generated.include_flags(root: ROOT),
                 '-I', File.join(ROOT, 'include'), '-I', ROOT, core, File.join(ROOT, DRIVER), '-o', output],
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
    source = File.read(File.join(ROOT, CORE))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
    path = File.join(@directory, "#{name.tr(' ', '-')}.c")
    File.write(path, source.sub(original) { replacement })
    build(path, name: "mutant-#{name}")
  end
end
