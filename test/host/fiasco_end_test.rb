# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/crash_frame'

# How each end of the machine ends it, on the host (docs/design-fiasco.md, "The end
# path"): the driver holds every cause to its end, and each seed below must make it
# name the end it broke. liberx/backend/fiasco/end_how.c is the core.
class FiascoEndTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/fiasco/end_how.c'
  DRIVER = 'test/fixtures/fiasco_end_driver.c'
  # Each seed moves one cause's case label to another cause's group: name => [the cause,
  # the cause whose group it joins, the driver's diagnostic]. The first four make an end nobody
  # ordered power off; the last makes a requested power-off reset.
  MUTANTS = {
    'a missed pet powers off' => ['PET', 'ASKED_OFF', 'a missed pet ends off, not reset'],
    'a root fault powers off' => ['FAULT', 'ASKED_OFF', 'a root fault ends off, not reset'],
    'the root stop powers off' => ['STOP', 'ASKED_OFF', "the root's stop ends off, not reset"],
    'a refusal powers off' => ['REFUSED', 'ASKED_OFF', 'a refusal ends off, not reset'],
    'a requested power-off resets' => ['ASKED_OFF', 'PET', 'a requested power-off ends reset, not off']
  }.freeze

  def self.label(cause) = "\tcase ERX_FIASCO_END_#{cause}:\n"

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-end-')
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:)
    output = File.join(@directory, name.tr(' ', '-'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'), '-I', ROOT, core, File.join(ROOT, DRIVER), '-o', output,
                                  stdin_data: '')
    assert status.success?, log
    output
  end

  def test_each_cause_ends_the_machine_as_the_design_says
    log, status = Open3.capture2e(build(File.join(ROOT, CORE), name: 'end'), stdin_data: '')
    assert status.success?, log
    assert_equal "end: 6 cases\n", log
  end

  # The core with the cause's label moved to the group of joins' label.
  def self.seeded(source, cause:, joins:)
    moved, kept = [cause, joins].map { |of| label(of) }
    raise "the core has no #{moved.strip} or #{kept.strip}" unless source.include?(moved) && source.include?(kept)

    source.sub(moved, '').sub(kept) { kept + moved }
  end

  MUTANTS.each do |name, (cause, joins, diagnostic)|
    define_method("test_mutant_#{name.tr(' -', '__')}") do
      seeded = File.join(@directory, "#{name.tr(' ', '-')}.c")
      File.write(seeded, FiascoEndTest.seeded(File.read(File.join(ROOT, CORE)), cause: cause, joins: joins))
      log, status = Open3.capture2e(build(seeded, name: "#{name} driver"), stdin_data: '')
      refute status.success?, "#{name}: the driver passed: #{log}"
      assert_includes log, diagnostic
    end
  end

  # The root's crash records (liberx/backend/fiasco/end_record.c): the boot image decides
  # the form, whatever the input names. Only a development image's root writes the full
  # form and the kernel's trace tail; a release image's, or one whose handoff the root has
  # not read, writes the brief form with nothing else (docs/design-debugger.md, "The
  # record's trace tail", "Who sees it").
  RECORD_CORE = 'liberx/backend/fiasco/end_record.c'
  RECORD_DRIVER = 'test/fixtures/fiasco_end_record_driver.c'
  RECORD_SOURCES = %w[kernel/core/crash.c kernel/core/log.c kernel/core/trace_ring.c].freeze

  def build_record_driver(core)
    output = File.join(@directory, 'end-record')
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'), '-I', ROOT,
                                  core, *RECORD_SOURCES.map { |file| File.join(ROOT, file) }, File.join(ROOT, RECORD_DRIVER),
                                  '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def record_lines(core)
    log, status = Open3.capture2e(build_record_driver(core), stdin_data: '')
    assert status.success?, log
    log.lines(chomp: true)
  end

  def test_only_a_development_image_writes_the_full_form_and_the_trace_tail
    brief = Erx::CrashFrame::BRIEF_SIZE
    lines = record_lines(File.join(ROOT, RECORD_CORE))
    assert_equal ["before the handoff: brief #{brief} trace 0", "a release image: brief #{brief} trace 0"], lines.first(2)
    assert_match(/\Aa development image: full \d+ trace 12\z/, lines.fetch(2))
    assert_match(/\Aa task's fault: full \d+ trace 0\z/, lines.fetch(3))
    assert_equal 4, lines.size
  end
end
