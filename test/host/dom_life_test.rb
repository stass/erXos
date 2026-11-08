# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the domain library's core after creation (liberx/system/dom_life.c)
# through its host driver, test/fixtures/dom_life_driver.c
# (docs/design-system.md, "Introducing two domains" and "Ending a domain").
# Bounds: one connection failed at every step and undone against the
# driver's own model of who pays for what, then disconnected whole; every
# refusal and result of connect, disconnect, retire and stop; the record
# step over each kind of record and record state; seeded plans that break
# the one-installer and reader-pays rules; and mutants, each judged by the
# line its seed must change.
class DomLifeTest < Minitest::Test
  LIFE = 'liberx/system/dom_life.c'
  EINVAL = -1
  ELIMIT = -7
  EBUSY = -8
  CRASH = -9_223_372_036_854_775_804
  NOTHREAD = -9_223_372_036_854_775_805
  # Kinds: teardown 1 disconnect, 2 destroy, 3 retire; action 0 drop, 1 stop,
  # 2 end; end 0 halt, 1 crash, 2 fault, 3 stopped.
  DROP = '0 kind=0'

  # Two carves, two sides, two bells, three installs into each party.
  LINK_STEPS = %w[CARVE CARVE MEM MEM BELL BELL INSTALL INSTALL INSTALL INSTALL INSTALL INSTALL].freeze

  # The side a reads is b's, 64 KiB of data plus its two pages, and a's bell:
  # a's child; b reads 16 KiB.
  CASES = {
    'connect_ok' => '0 number=20 row=2 slots=0,1 labels=2,4 children=77824,28672',
    'connect_same' => EINVAL, 'connect_unknown' => EINVAL, 'connect_system' => EINVAL,
    'connect_ended' => EINVAL, 'connect_building' => EINVAL, 'connect_lane_odd' => EINVAL,
    'connect_lane_zero' => EINVAL, 'connect_lane_large' => EINVAL,
    'connect_quota' => ELIMIT, 'connect_quota_closing' => ELIMIT, 'connect_table_full' => ELIMIT,
    'connect_numbers_spent' => ELIMIT, 'connect_labels_spent' => ELIMIT,
    'connect_labels_last' => '0 number=20 row=2 slots=0,1 labels=2147483647,4 children=77824,77824',
    'connect_labels_unset' => ELIMIT,
    'disconnect_system' => '0 kind=1 index=0 destroy=511',
    'disconnect_pair' => '0 kind=1 index=3 destroy=521,621',
    'disconnect_zero' => EINVAL, 'disconnect_unknown' => EINVAL,
    'retire_ok' => '0 kind=3 index=2 destroy=702',
    'retire_running' => EINVAL, 'retire_unknown' => EINVAL, 'retire_zero' => EINVAL,
    'retire_busy' => EBUSY, 'retire_busy_system' => EBUSY
  }.freeze

  ACTS = {
    'stop_ok' => '0 kind=1 slot=0 status=3 end=3,0',
    'stop_crash_status' => "0 kind=1 slot=1 status=#{CRASH} end=3,0",
    'stop_ended' => EINVAL, 'stop_building' => EINVAL, 'stop_unknown' => EINVAL,
    'stop_parent_status' => EINVAL, 'stop_released_status' => EINVAL, 'stop_nothread_status' => EINVAL,
    'fault_running' => "0 kind=1 slot=0 status=#{CRASH} end=2,1",
    'exit_halt' => '0 kind=2 slot=0 status=0 end=0,0 teardown=2,0,501',
    'exit_halt_status' => '0 kind=2 slot=1 status=0 end=0,42 teardown=2,1,601',
    'exit_nothread' => "0 kind=2 slot=0 status=0 end=0,#{NOTHREAD} teardown=2,0,501",
    'exit_crash' => '0 kind=2 slot=0 status=0 end=1,0 teardown=2,0,501',
    'exit_library_unnoted' => '0 kind=2 slot=0 status=0 end=3,0 teardown=2,0,501',
    'exit_ended' => DROP, 'fault_ended' => DROP, 'exit_building' => DROP, 'exit_unknown' => DROP,
    'exit_system' => DROP, 'exit_wide_label' => DROP,
    'stop_again' => DROP, 'fault_stopping' => DROP,
    'exit_fault_noted' => '0 kind=2 slot=0 status=0 end=2,3 teardown=2,0,501',
    'exit_stopped' => '0 kind=2 slot=1 status=0 end=3,0 teardown=2,1,601',
    'exit_halt_first' => '0 kind=2 slot=0 status=0 end=0,2 teardown=2,0,501',
    'exit_crash_first' => '0 kind=2 slot=1 status=0 end=1,0 teardown=2,1,601'
  }.freeze

  SEEDED = %w[foreign_gate creation_object extra_right peer_side_writable creation_space writer_pays
              child_from_peer child_from_principal bell_on_peer_group bell_label_zero bell_label_split
              out_of_order made_twice too_many obj_range same_party number_zero].freeze

  # One-line edits of the core, each with the driver line it must change.
  MUTANTS = {
    'quota counts the system connection' =>
      ['if (row->number != 0 && row->a != ERX_DOM_SYSTEM_ID &&', 'if (row->number != 0 &&', 'case connect_ok '],
    'side charged to the writer' =>
      ['.budget = ERX_DOM_OBJ_LINK_BUDGET_A, .size = side_b };',
       '.budget = ERX_DOM_OBJ_LINK_BUDGET_B, .size = side_b };', 'case connect_ok '],
    'retire ignores connections' => ['return (ERX_EBUSY);', 'continue;', 'case retire_busy '],
    'disconnect destroys a system connection\'s null child' =>
      ["if (row->a != ERX_DOM_SYSTEM_ID)\n\t\t\tdraft.destroy", "draft.destroy", 'case disconnect_system '],
    'classify trusts a stop the library did not make' =>
      ["\tif (by_library)\n", "\tif (by_library || noted != NULL)\n", 'act exit_halt_first '],
    'library threads ignored' =>
      ['if (view->library_threads[index] == thread)', 'if (view->library_threads[index] == ~thread)', 'act exit_library_unnoted '],
    'a second fault restarts the stop' => ["\tif (dom->stopping)\n\t\treturn;\n", '', 'act fault_stopping '],
    'connect admits an ended domain' =>
      ['dom->state == ERX_DOM_RUNNING);', 'dom->state == ERX_DOM_RUNNING ||' \
                                          ' dom->state == ERX_DOM_ENDED);', 'case connect_ended '],
    'a record with no system label connects' =>
      ['dom->labels >= ERX_DOM_SYSTEM_LABEL &&', 'true &&', 'case connect_labels_unset '],
    'stop takes a kernel status' => ['status == ERX_EXIT_PARENT || ', '', 'act stop_parent_status '],
    'install check ignores the space' =>
      ['if (row->obj == step->obj && row->target == step->target &&', 'if (row->obj == step->obj &&',
       'seeded creation_space ']
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-dom-life-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, LIFE), name: 'dom-life')
  end

  def test_every_failed_connection_is_undone_and_a_disconnect_leaves_nothing
    lines = run_driver(driver, 'explore')
    assert_empty lines.grep(/\AFAIL/), 'a failed or disconnected connection left something behind'
    assert_equal "steps #{LINK_STEPS.join(' ')}", lines.first
    assert_equal "explore steps=#{LINK_STEPS.size} failures=0", lines.last
  end

  def test_every_result_of_connect_disconnect_and_retire
    assert_results('case', CASES, run_driver(driver, 'cases'))
  end

  # A stop the library made is the end it noted, whichever record comes
  # first; a stop the domain made is its own status.
  def test_the_record_step_and_stop_classify_every_end
    assert_results('act', ACTS, run_driver(driver, 'cases'))
  end

  def test_seeded_connections_fail_the_check
    lines = run_driver(driver, 'seeded')
    assert_includes lines, 'seeded valid 0'
    SEEDED.each { |name| assert_includes lines, "seeded #{name} #{EINVAL}", name }
    assert_equal SEEDED.size + 1, lines.size
  end

  def test_each_mutant_changes_its_line
    clean = %w[explore cases seeded].flat_map { |mode| run_driver(driver, mode) }
    MUTANTS.each do |name, (from, to, line)|
      text = File.read(File.join(@root, LIFE))
      assert_equal 1, text.scan(from).size, "the #{name} seed no longer applies"
      mutated = File.join(@directory, "mutant-#{name.tr(" '", '--')}.c")
      File.write(mutated, text.sub(from) { to })
      mutant = build_driver(mutated, name: "mutant-#{name.tr(" '", '--')}")
      lines = %w[explore cases seeded].flat_map { |mode| run_driver(mutant, mode, check: false) }
      refute_equal clean.grep(/\A#{Regexp.escape(line)}/), lines.grep(/\A#{Regexp.escape(line)}/),
                   "mutant survived: #{name}"
    end
  end

  private

  def assert_results(prefix, expected, lines)
    results = lines.grep(/\A#{prefix} /).to_h { |entry| entry.split(' ', 3).then { |_, name, rest| [name, rest] } }
    assert_equal expected.keys.sort, results.keys.sort, 'the driver and the test name the same cases'
    expected.each { |name, want| assert_equal want.to_s, results.fetch(name), name }
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(life, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-Wswitch-enum',
                 '-pedantic', '-O1', '-g', *@flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), File.join(@root, 'liberx/system/dom_core.c'), life,
                 File.join(@root, 'liberx/erx_lane.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'test/fixtures/dom_life_driver.c'), '-o', output],
                name: "dom-life-#{name}", deadline: 120)
    output
  end

  # A mutant may exit non-zero; its lines are still judged.
  def run_driver(path, mode, check: true)
    record = @runner.run([path, mode], name: "dom-life-run-#{mode}", deadline: 60)
    File.readlines(record.fetch('log'), chomp: true)
  rescue Erx::CommandError => error
    raise if check

    File.readlines(error.result.fetch('log'), chomp: true)
  end
end
