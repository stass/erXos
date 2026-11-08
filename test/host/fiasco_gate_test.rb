# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The fault gates' core on the host: the driver test/fixtures/gate_driver.c runs it
# exhaustively and under real threads, and each seed below must make it name what
# it broke.
class FiascoGateTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORES = %w[liberx/backend/core/gate.c liberx/backend/core/grow_table.c].freeze
  DRIVER = 'test/fixtures/gate_driver.c'

  # name => [original, replacement, mode, the driver's diagnostic]; each edits one place in gate.c.
  MUTANTS = {
    'owed down removed' => ["\t\tif (!effects->cancel(context))\n\t\t\teffects->absorb(context);\n",
                            "\t\t(void)effects->cancel(context);\n", 'protocol', 'stale count'],
    'post wakes nobody' => ["\tgate->tail = entry;\n\treturn (gate_wake(gates, gate));\n", "\tgate->tail = entry;\n\treturn (ERX_BACKEND_GATE_NO_THREAD);\n",
                            'exhaustive', 'lost wake'],
    'take ignores the binding' => ['gate->thread == thread && gate->head != NULL', 'gate->head != NULL', 'exhaustive', 'a take'],
    'take keeps the newest' => ['gate->head->order < oldest->order', 'gate->head->order > oldest->order', 'exhaustive', 'a take'],
    'close keeps the queue' => ["\twhile (gate->head != NULL)\n\t\tgate_unlink(gate->head);\n", '', 'exhaustive', 'queued'],
    'deletion keeps the binding' => ["\t\tif (gate != NULL && gate->thread == thread)\n\t\t\tgate->thread = ERX_BACKEND_GATE_NO_THREAD;\n",
                                     "\t\t(void)gate;\n", 'exhaustive', 'binding']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-gate-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(cores, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                                  '-D_DARWIN_C_SOURCE', *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, *cores,
                                  File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def real_cores = CORES.map { |core| File.join(ROOT, core) }

  def test_every_mode_agrees
    driver = build(real_cores, name: 'driver')
    %w[exhaustive protocol race].each do |mode|
      log, status = Open3.capture2e(driver, mode, stdin_data: '')
      assert status.success?, "#{mode}: #{log}"
      assert_match(/\A#{mode}: [1-9]/, log)
    end
  end

  def test_wait_and_post_race_under_thread_sanitizer
    driver = build(real_cores, name: 'driver-tsan', flags: %w[-fsanitize=thread -fno-omit-frame-pointer])
    log, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: compiler), driver, 'race', stdin_data: '')
    assert status.success?, log
    assert_match(/\Arace: [1-9]/, log)
  end

  MUTANTS.each do |name, (original, replacement, mode, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, CORES.first))
      assert_includes source, original, 'the seed no longer applies'
      seeded = File.join(@directory, File.basename(CORES.first))
      File.write(seeded, source.sub(original) { replacement })
      driver = build([seeded, File.join(ROOT, CORES.last)], name: "seed-#{name}", flags: [])
      log, status = Open3.capture2e(driver, mode, stdin_data: '')
      refute status.success?, "#{name}: the driver saw nothing: #{log}"
      assert_includes log, diagnostic
    end
  end
end
