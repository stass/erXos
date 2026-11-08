# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/chokepoint_rules'
require_relative '../../tools/lib/erx/sanitizer_tests'

# Discovery fails loudly: a missing, empty or malformed declaration stops the
# gate that would otherwise run less, for all three kinds of declaration.
class GateDiscoveryTest < Minitest::Test
  Rules = Erx::ChokepointRules
  Fuzz = Erx::PackFuzz
  Sanitizers = Erx::SanitizerTests
  DECLARED = "# erx-gate: sanitizers\n"

  def with_files(files)
    Dir.mktmpdir('erx-gate-discovery-') do |directory|
      files.each { |name, text| File.write(File.join(directory, name), text) }
      yield directory
    end
  end

  def refusal(pattern, &block)
    error = assert_raises(Erx::Error, &block)
    assert_match(pattern, error.message)
  end

  # A chokepoint group file that declares nothing, an empty group, or a group
  # with rules that are not rules does not load, and the loader names the file.
  def test_a_malformed_chokepoint_group_does_not_load
    {
      'silent.rb' => ["# no declaration\n", /silent\.rb declares nothing/],
      'empty.rb' => ["Erx::ChokepointRules.declare_group\n", /declares rules, or none:/],
      'both.rb' => ["Erx::ChokepointRules.declare_group(rules: Erx::ChokepointRules::ALL.first(1), none: 'x')\n",
                    /declares rules, or none:/],
      'stray.rb' => ["Erx::ChokepointRules.declare_group(rules: ['not a rule'])\n", /not a rule/],
      'blank.rb' => ["Erx::ChokepointRules.declare_group(none: '  ')\n", /declares rules, or none:/],
      'twice.rb' => ["2.times { Erx::ChokepointRules.declare_group(none: 'x') }\n", /twice\.rb declares 2 times/],
      'Bad-Name.rb' => ["Erx::ChokepointRules.declare_group(none: 'x')\n", /Bad-Name\.rb is not named/]
    }.each do |name, (text, pattern)|
      with_files(name => text) { |directory| refusal(pattern) { Rules.load_groups(directory) } }
    end
  end

  def test_chokepoint_groups_load_in_sorted_order_by_file_name
    with_files('b_core.rb' => "Erx::ChokepointRules.declare_group(none: 'b')\n",
               'a_core.rb' => "Erx::ChokepointRules.declare_group(none: 'a')\n") do |directory|
      groups = Rules.load_groups(directory)
      assert_equal %w[a_core b_core], groups.keys
      assert_equal 'a', groups.fetch('a_core').none
    end
  end

  def test_an_empty_rules_directory_does_not_load
    with_files({}) { |directory| refusal(/no \*\.rb file/) { Rules.load_groups(directory) } }
  end

  def test_a_declaration_outside_a_loading_file_is_refused
    refusal(/outside a file being loaded/) { Rules.declare_group(none: 'x') }
    refusal(/outside a file being loaded/) { Fuzz.declare_target(sources: ['a.c'], seeds: { 'a' => 'b' }) }
  end

  # A core whose group file was deleted, misnamed or never written stops the
  # load, and a group for every core in the tree is what let this file load.
  def test_a_core_without_a_group_stops_the_load
    refusal(%r{kernel/core/cap\.c has no group: add tools/lib/erx/chokepoint_rules/cap\.rb}) do
      Rules.require_core_groups(['kernel/core/cap.c'], Rules::GROUPS.keys - ['cap'])
    end
    refusal(%r{kernel/sched/run\.c has no group}) do
      Rules.require_core_groups(['kernel/core/cap.c', 'kernel/sched/run.c'], %w[cap capp])
    end
    assert_nil Rules.require_core_groups(['kernel/core/cap.c'], %w[cap])
    root = File.expand_path('../..', __dir__)
    cores = Dir.glob('kernel/{core,sched}/*.c', base: root).map { |source| File.basename(source, '.c') }
    refute_empty cores
    assert_empty cores - Rules::GROUPS.keys
  end

  def test_a_group_without_a_rule_states_why
    %w[admit pack rng tlb_plan watchdog].each do |core|
      group = Rules::GROUPS.fetch(core)
      assert_empty group.rules
      refute_empty group.none
    end
    assert_nil Rules::GROUPS.fetch('cap').none
  end

  # The group files share one module, so one that assigned another's constant
  # or redefined a helper would change that group's rules with only a warning.
  def test_the_group_files_share_no_constant_and_define_no_helper
    root = File.expand_path('../../tools/lib/erx', __dir__)
    files = [File.join(root, 'chokepoint_rules.rb'), *Dir.glob(File.join(root, 'chokepoint_rules/*.rb'))]
    assigned = files.flat_map do |file|
      File.read(file).scan(/^\s*((?:[A-Z]\w*,\s*)*[A-Z]\w*)\s*=[^=~>]/).flatten.flat_map { |names| names.split(/,\s*/) }.uniq
    end
    assert_includes assigned, 'ERXOS_C'
    assert_includes assigned, 'TRAP_OPCODE'
    assert_empty assigned.tally.select { |_name, count| count > 1 }.keys
    (files - files.first(1)).each { |file| refute_match(/^\s*def\s/, File.read(file), file) }
  end

  def test_an_object_leg_exemption_comes_from_its_group
    object_leg = Rules::ALL.find { |rule| rule.name == 'object-leg' }
    assert_includes Rules::GROUPS.fetch('lane').unchecked_objects, 'liberx/erx_lane.c'
    assert_empty Rules::GROUPS.values.flat_map(&:unchecked_objects) - object_leg.existing
  end

  def test_a_private_header_site_permits_only_its_groups_headers
    records = Rules::ALL.find { |rule| rule.name == 'core-records-private' }
    site = records.sites.find { |candidate| candidate.glob == Rules::BUDGET_DRIVER }
    assert_match site.permits, "#include \"budget_impl.h\"\n"
    refute_match site.permits, "#include \"cap_impl.h\"\n"
  end

  def test_the_kinds_are_read_from_the_rules
    assert_equal Rules::ALL.size, [Rules::ACTIVE, Rules::CALL_GRAPH, Rules::ELSEWHERE, Rules::PENDING].sum(&:size)
    assert_includes Rules::CALL_GRAPH.map(&:name), 'cap-slot-clear-callers'
    assert_includes Rules::PENDING.map(&:name), 'grace-tracker-lock'
    assert_includes Rules::ACTIVE.map(&:name), 'include-form'
  end

  VALID_TARGET = "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { 'seed-0' => 'x' })\n"

  def test_a_fuzz_declaration_is_validated
    {
      'no sources' => "Erx::PackFuzz.declare_target(sources: [], seeds: { 'a' => 'b' })\n",
      'no seeds' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: {})\n",
      'seeds of no shape' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: ['b'])\n",
      'a seed name that is a path' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { '../a' => 'b' })\n",
      'seed bytes that are not bytes' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { 'a' => 1 })\n",
      'an absolute source' => "Erx::PackFuzz.declare_target(sources: ['/a.c'], seeds: { 'a' => 'b' })\n",
      'a climbing source' => "Erx::PackFuzz.declare_target(sources: ['../a.c'], seeds: { 'a' => 'b' })\n",
      'no include paths' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { 'a' => 'b' }, includes: [])\n",
      'a define that is a flag' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { 'a' => 'b' }, defines: ['X -O0'])\n",
      'a define with a value' => "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { 'a' => 'b' }, defines: ['X=1'])\n"
    }.each do |label, text|
      with_files('x_fuzz.c' => '', 'x_target.rb' => text) do |directory|
        assert_raises(Erx::Error, label) { Fuzz.load_targets(directory) }
      end
    end
  end

  def test_a_fuzz_entry_and_its_declaration_need_each_other
    with_files('x_fuzz.c' => '', 'y_fuzz.c' => '', 'x_target.rb' => VALID_TARGET) do |directory|
      refusal(/y needs both/) { Fuzz.load_targets(directory) }
    end
    with_files('x_fuzz.c' => '', 'x_target.rb' => VALID_TARGET, 'z_target.rb' => VALID_TARGET) do |directory|
      refusal(/z needs both/) { Fuzz.load_targets(directory) }
    end
    with_files('x_fuzz.c' => '') { |directory| refusal(/no \*_target\.rb file/) { Fuzz.load_targets(directory) } }
    with_files('x_fuzz.c' => '', 'x_target.rb' => "# nothing\n") do |directory|
      refusal(/declares nothing/) { Fuzz.load_targets(directory) }
    end
  end

  def test_a_valid_fuzz_declaration_takes_the_default_includes_and_its_files_name
    with_files('x_fuzz.c' => '', 'x_target.rb' => VALID_TARGET) do |directory|
      target = Fuzz.load_targets(directory).first
      assert_equal 'x', target.kind
      assert_equal ['a.c'], target.sources
      assert_equal Fuzz::INCLUDES, target.includes
      assert_empty target.defines
      assert_equal({ 'seed-0' => 'x' }, target.seeds)
    end
  end

  def test_a_fuzz_targets_defines_reach_its_compile
    text = "Erx::PackFuzz.declare_target(sources: ['a.c'], seeds: { 'a' => 'b' }, defines: ['ERX_HOST'])\n"
    with_files('x_fuzz.c' => '', 'x_target.rb' => text) do |directory|
      target = Fuzz.load_targets(directory).first
      assert_includes Fuzz.compile_command(target, root: '/r', compiler: 'cc', program: 'p'), '-DERX_HOST'
    end
  end

  def test_the_trees_fuzz_targets_each_have_their_entry_and_a_deadline_for_all
    root = File.expand_path('../..', __dir__)
    refute_empty Fuzz.targets
    Fuzz.targets.each { |target| assert File.file?(File.join(root, "tools/fuzz/#{target.kind}_fuzz.c")), target.kind }
    Fuzz.targets.flat_map(&:sources).each { |source| assert File.file?(File.join(root, source)), source }
    assert_equal Fuzz.targets.size * (Fuzz::COMPILE_DEADLINE + Fuzz::RUN_DEADLINE), Fuzz.deadline
  end

  def select(tests, switch_helpers: [], sources: []) = Sanitizers.select(tests, switch_helpers: switch_helpers, sources: sources)

  def test_the_sanitizer_gate_runs_exactly_the_tests_that_declare_it
    assert_equal %w[a_test.rb c_test.rb],
                 select({ 'c_test.rb' => DECLARED, 'b_test.rb' => "# other\n", 'a_test.rb' => "x\n#{DECLARED}" })
    # A declaration in a string, with text before it, is not a declaration.
    assert_equal %w[a_test.rb], select({ 'a_test.rb' => DECLARED, 'b_test.rb' => "x = \"#{DECLARED.chomp}\"\n" })
  end

  # The test pool's serial declaration shares the `erx-gate` comment style and
  # is the one other line discovery accepts; a misspelling of it is refused.
  def test_the_serial_declaration_is_accepted_beside_the_sanitizer_one_and_misspelt_ones_are_refused
    both = "#{DECLARED}# erx-gate: serial\n"
    assert_equal %w[a_test.rb b_test.rb], select({ 'a_test.rb' => both, 'b_test.rb' => "# erx-gate: serial\n#{DECLARED}" })
    ['# erx-gate: serail', '# erx-gate:serial', '# erx-gate: serial, sanitizers'].each do |line|
      refusal(/malformed declaration/) { select({ 'a_test.rb' => DECLARED, 'b_test.rb' => "#{line}\n" }) }
    end
  end

  def test_a_gate_nothing_declares_is_refused
    refusal(/no test declares it/) { select({ 'a_test.rb' => "# nothing\n" }) }
    refusal(/no test declares it/) { select({}) }
  end

  def test_a_malformed_sanitizer_declaration_is_refused
    ['# erx-gate: sanitizer', '# erx-gate:sanitizers', '# erx_gate: sanitizers', '#erx-gate: sanitizers',
     '# ERX-GATE: sanitizers', '# erx-gate: sanitizers, address', '# erx-gate:', '# erx-gates: sanitizers',
     '#-erx-gate: sanitizers', '# # erx-gate: sanitizers'].each do |line|
      refusal(/malformed declaration/) { select({ 'a_test.rb' => DECLARED, 'b_test.rb' => "#{line}\n" }) }
    end
  end

  # A test that builds its C by the switch, directly or through a helper that
  # reads it, cannot stay out of the gate by forgetting the line. Each read is
  # assembled here so that this file does not itself read as one.
  def test_a_test_reading_the_switch_must_declare
    switch = "#{'ENV'}.fetch('ERX_SANITIZERS', '')"
    ["sanitizers = #{switch}\n", "s = #{'ENV'}['ERX_SANITIZERS']\n", "s = #{'ENV'}.fetch(\"ERX_SANITIZERS\", 1)\n"].each do |read|
      refusal(/b_test\.rb reads the sanitizer switch/) { select({ 'a_test.rb' => DECLARED, 'b_test.rb' => read }) }
    end
    read = "sanitizers = #{switch}\n"
    assert_equal %w[a_test.rb b_test.rb], select({ 'a_test.rb' => DECLARED, 'b_test.rb' => "#{DECLARED}#{read}" })
    ["require_relative '../fixtures/native_fixture'\n", "require_relative \"../fixtures/native_fixture\"\n",
     "require 'native_fixture'\n"].each do |via|
      refusal(/b_test\.rb reads the sanitizer switch/) do
        select({ 'a_test.rb' => DECLARED, 'b_test.rb' => via }, switch_helpers: ['test/fixtures/native_fixture.rb'])
      end
    end
  end

  # A core's or liberx source's test need not be named after it, as
  # kernel/core/admit.c's is not, but some declaring test must name it.
  def test_a_source_must_be_named_by_a_declaring_test
    tests = { 'test/host/a_test.rb' => "#{DECLARED}# drives kernel/core/a.c and liberx/l.c\n",
              'test/host/b_test.rb' => "# drives kernel/core/b.c\n" }
    assert_equal ['test/host/a_test.rb'], select(tests, sources: %w[kernel/core/a.c liberx/l.c])
    refusal(%r{names kernel/core/b\.c}) { select(tests, sources: %w[kernel/core/a.c kernel/core/b.c]) }
    refusal(%r{names kernel/sched/c\.c}) { select(tests, sources: ['kernel/sched/c.c']) }
  end

  # The fixture that reads the switch is found in the tree, and its tests are
  # in the gate.
  def test_the_trees_switch_fixture_is_seen
    root = File.expand_path('../..', __dir__)
    tests = Sanitizers.discover(root: root)
    assert_includes tests, 'test/host/crypto_test.rb'
    text = File.read(File.join(root, 'test/host/crypto_test.rb'))
    error = assert_raises(Erx::Error) do
      Sanitizers.select({ 'test/host/a_test.rb' => DECLARED, 'test/host/crypto_test.rb' => text.sub(DECLARED, '') },
                        switch_helpers: ['test/fixtures/crypto_fixture.rb'], sources: [])
    end
    assert_match(/crypto_test\.rb reads the sanitizer switch/, error.message)
  end
end
