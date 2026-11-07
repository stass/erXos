# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'

# erx-gate: sanitizers

# The backends' park core and the Fiasco backend's thread claim, on the host
# (docs/design-stopgap.md, "Verification", "Park", "Claim"): the drivers walk every
# order, and each seed below must make its driver name what it broke.
class FiascoParkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PARK = 'liberx/backend/core/park_table.c'
  CLAIM = 'liberx/backend/fiasco/thread_claim.c'
  PARK_DRIVER = 'test/fixtures/fiasco_park_driver.c'
  CLAIM_DRIVER = 'test/fixtures/fiasco_claim_driver.c'

  # name => [core, driver, original, replacement, mode, the driver's diagnostic].
  MUTANTS = {
    'a plain trigger skips the advance' => [PARK, PARK_DRIVER, "case ERX_BACKEND_PARK_OP_TRIGGER:\n\t\tpark->group_epoch++;\n", "case ERX_BACKEND_PARK_OP_TRIGGER:\n", 'calls', 'a plain trigger'],
    'epoch comparison removed' => [PARK, PARK_DRIVER,
                                   "if (park->group_epoch != event->group_seen || park->slot_epoch[slot] != event->slot_seen)\n\t\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_RETURN });\n",
                                   '', 'exhaustive', 'a lost wake'],
    'group epoch not compared' => [PARK, PARK_DRIVER, 'park->group_epoch != event->group_seen || ', '', 'exhaustive', 'a lost wake'],
    'slot epoch not compared' => [PARK, PARK_DRIVER, ' || park->slot_epoch[slot] != event->slot_seen', '', 'exhaustive', 'a lost wake'],
    'a signal skips the advance' => [PARK, PARK_DRIVER, "\t\tpark->group_epoch++;\n\t\tif ((park->listed", "\t\tif ((park->listed", 'exhaustive', 'a lost wake'],
    'listed flag ignored' => [PARK, PARK_DRIVER, 'if ((park->listed & (UINT64_C(1) << event->object)) == 0) {', '{', 'exhaustive', 'a label twice'],
    'a take keeps the flag' => [PARK, PARK_DRIVER, "\tpark->listed &= ~(UINT64_C(1) << object);\n", '', 'exhaustive', 'a lost wake'],
    'a signal lists nothing' => [PARK, PARK_DRIVER, "park->ready[park->ready_count++] = (uint8_t)event->object;\n", '', 'exhaustive', 'a lost wake'],
    'a take ignores max' => [PARK, PARK_DRIVER, 'while (count < max) {', 'while (count < max + ERX_BACKEND_PARK_OBJECTS_MAX) {', 'calls', 'a take ignored max'],
    'an object out of range taken' => [PARK, PARK_DRIVER, "if (event->object >= ERX_BACKEND_PARK_OBJECTS_MAX)\n\t\t\tbreak;\n", '', 'calls', 'out of range'],
    'wake skips the advance' => [PARK, PARK_DRIVER, "park->slot_epoch[slot]++;\n", '', 'exhaustive', 'a lost wake'],
    'an up to a slot not listed' => [PARK, PARK_DRIVER, "if (park_leave(park, slot))\n\t\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_UP, .slot = slot });\n\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_NOTHING });\n",
                                     "(void)park_leave(park, slot);\n\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_UP, .slot = slot });\n", 'exhaustive', 'a stale count'],
    'a timeout not owed anything' => [PARK, PARK_DRIVER, 'park_leave(park, slot) ? ERX_BACKEND_PARK_TIMED_OUT :
		    ERX_BACKEND_PARK_OWED', '(park_leave(park, slot), ERX_BACKEND_PARK_TIMED_OUT)', 'exhaustive', 'a stale count'],
    'a trigger takes the newest' => [PARK, PARK_DRIVER, 'slot = park->parked[0];', 'slot = park->parked[park->parked_count - 1];', 'exhaustive', 'oldest first'],
    'the claim ignores the marker' => [CLAIM, CLAIM_DRIVER, ' && view->marker(context, index) == 0', '', nil, 'kernel\'s write still to come'],
    'a release wakes nobody' => [PARK, PARK_DRIVER, "park->used &= ~(UINT64_C(1) << slot);\n\t\tpark->group_epoch++;\n\t\treturn (park_take_oldest(park));", "park->used &= ~(UINT64_C(1) << slot);\n\t\tpark->group_epoch++;\n\t\treturn ((erx_backend_park_result_t){ .action = ERX_BACKEND_PARK_NOTHING });", 'calls', 'a release did not wake the oldest'],
    'a slot parked twice' => [PARK, PARK_DRIVER, ' || park_on_list(park, slot))', ')', 'calls', 'a slot parked twice'],
    'an empty slot not refused' => [PARK, PARK_DRIVER, "if (!park_slot_valid(park, slot))\n\t\t\tbreak;\n\t\tpark->slot_epoch[slot]++;", 'park->slot_epoch[slot % ERX_GROUP_EXECUTORS_MAX]++;', 'calls', 'an empty slot']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-park-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build(core, driver, name:, flags: @sanitizer_flags)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread',
                                  '-D_DARWIN_C_SOURCE', *flags, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, core,
                                  File.join(ROOT, driver), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def run_driver(driver, *mode, env: {}) = Open3.capture2e(env, driver, *mode, stdin_data: '')

  def test_every_park_mode_agrees
    driver = build(File.join(ROOT, PARK), PARK_DRIVER, name: 'park')
    %w[exhaustive calls race ready].each do |mode|
      log, status = run_driver(driver, mode)
      assert status.success?, "#{mode}: #{log}"
      assert_match(/\A#{mode}: [1-9]/, log)
    end
  end

  def test_every_claim_order_agrees
    log, status = run_driver(build(File.join(ROOT, CLAIM), CLAIM_DRIVER, name: 'claim'))
    assert status.success?, log
    assert_match(/\Aclaim: [1-9]/, log)
  end

  def test_park_race_under_thread_sanitizer
    driver = build(File.join(ROOT, PARK), PARK_DRIVER, name: 'park-tsan', flags: %w[-fsanitize=thread -fno-omit-frame-pointer])
    log, status = run_driver(driver, 'race', env: { 'TSAN_OPTIONS' => 'halt_on_error=1' })
    assert status.success?, log
    assert_match(/\Arace: [1-9]/, log)
  end

  MUTANTS.each do |name, (core, driver_source, original, replacement, mode, diagnostic)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      source = File.read(File.join(ROOT, core))
      assert_includes source, original, 'the seed no longer applies'
      seeded = File.join(@directory, File.basename(core))
      File.write(seeded, source.sub(original) { replacement })
      driver = build(seeded, driver_source, name: "seed-#{name}", flags: [])
      log, status = run_driver(driver, *mode)
      refute status.success?, "#{name}: the driver saw nothing: #{log}"
      assert_includes log, diagnostic
    end
  end
end
