# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# erx-gate: sanitizers

# The Fiasco backend's umtx core and service decoder, on the host: the driver
# test/fixtures/fiasco_umtx_driver.c runs them exhaustively and under real threads,
# and each seed below must make it name what it broke.
class FiascoUmtxTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  UMTX = 'liberx/backend/fiasco/umtx_table.c'
  WIRE = 'liberx/backend/fiasco/service_wire.c'
  DRIVER = 'test/fixtures/fiasco_umtx_driver.c'

  # name => [core, original, replacement, mode, the driver's diagnostic].
  MUTANTS = {
    'compare outside the lock' => [UMTX,
                                   "\teffects->lock(context);\n\tif (atomic_load_explicit(word, memory_order_acquire) != expected) {\n\t\teffects->unlock(context);\n\t\treturn (ERX_OK);\n\t}\n",
                                   "\tif (atomic_load_explicit(word, memory_order_acquire) != expected)\n\t\treturn (ERX_OK);\n\teffects->lock(context);\n",
                                   'protocol', 'lost wake'],
    'absorb removed' => [UMTX, "\teffects->absorb(context, node);\n", '', 'protocol', 'stale count'],
    'wake takes the newest' => [UMTX, "for (node = table->head[umtx_bucket(addr)]; node != NULL && found < count; node = following) {\n\t\tfollowing = node->next;",
                                "for (node = table->tail[umtx_bucket(addr)]; node != NULL && found < count; node = following) {\n\t\tfollowing = node->prev;",
                                'exhaustive', 'oldest first'],
    'word ignored by a take' => [UMTX, "\t\tif (node->addr != addr)\n\t\t\tcontinue;\n", '', 'exhaustive', 'a take'],
      'word count unchecked' => [WIRE, 'expected == 0 || input->words != expected || ', 'expected == 0 || ', 'wire', 'word count'],
    'caller unchecked' => [WIRE, ' || input->mr[0] >= ERX_FIASCO_THREADS_MAX', '', 'wire', 'thread index'],
    'rights in the label kept' => [WIRE, 'input->label >> ERX_FIASCO_WIRE_LABEL_SHIFT', 'input->label', 'wire', 'rights']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-umtx-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(cores, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                                  '-D_DARWIN_C_SOURCE', *flags, '-I', File.join(ROOT, 'include'), '-I', ROOT, *cores,
                                  File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def real_cores = [UMTX, WIRE].map { |core| File.join(ROOT, core) }

  def test_every_mode_agrees
    driver = build(real_cores, name: 'driver')
    %w[exhaustive protocol wire].each do |mode|
      log, status = Open3.capture2e(driver, mode, stdin_data: '')
      assert status.success?, "#{mode}: #{log}"
      assert_match(/\A#{mode}: [1-9]/, log)
    end
  end

  def test_wait_and_wake_race_under_thread_sanitizer
    driver = build(real_cores, name: 'driver-tsan', flags: %w[-fsanitize=thread -fno-omit-frame-pointer])
    log, status = Open3.capture2e({ 'TSAN_OPTIONS' => 'halt_on_error=1' }, driver, 'race', stdin_data: '')
    assert status.success?, log
    assert_match(/\Arace: [1-9]/, log)
  end

  MUTANTS.each do |name, (core, original, replacement, mode, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, core))
      assert_includes source, original, 'the seed no longer applies'
      seeded = File.join(@directory, File.basename(core))
      File.write(seeded, source.sub(original) { replacement })
      others = real_cores.reject { |path| path.end_with?(core) }
      driver = build([seeded, *others], name: "seed-#{name}", flags: [])
      log, status = Open3.capture2e(driver, mode, stdin_data: '')
      refute status.success?, "#{name}: the driver saw nothing: #{log}"
      assert_includes log, diagnostic
    end
  end
end
