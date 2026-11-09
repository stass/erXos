# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the domain library's pure core (liberx/system/dom_core.c) through
# its host driver, test/fixtures/dom_core_driver.c (docs/design-system.md,
# "The domain library" and "Creating a domain"). Bounds: four creation
# variants (a request, a request with sub-spaces and a JIT runtime, a
# configured domain, a partial-boot program), each failed at every step
# in turn and undone against the driver's own model of budgets; one
# mutation of a valid specification per refusal the planner makes; and
# seeded plans that break the one-installer rule and the charging rule.
class DomCoreTest < Minitest::Test
  CORE = 'liberx/system/dom_core.c'
  EINVAL = -1
  ENOMEM = -6
  ELIMIT = -7
  EBUSY = -8

  # The creation order of design-system.md, "Creating a domain", step 2.
  REQUEST_STEPS = %w[CARVE:BUDGET CARVE:OUTER SPACE:SPACE GROUP:GROUP MEM:BOOTINFO MEM:CRASH
                     CARVE:SYS_BUDGET MEM:SYS_SIDE MEM:DOM_SIDE BELL:SYS_BELL BELL:DOM_BELL
                     SLICE:SLICE IMAGE_MAP:SPACE MAP:SLICE MAP:BOOTINFO
                     INSTALL:BUDGET INSTALL:GROUP INSTALL:DOM_SIDE INSTALL:SYS_SIDE INSTALL:SYS_BELL
                     INSTALL:TIME_PAGE INSTALL:SLICE INSTALL:CRASH BOOTINFO:BOOTINFO THREAD:THREAD].freeze
  PARTIAL_STEPS = %w[CARVE:BUDGET CARVE:OUTER SPACE:SPACE GROUP:GROUP MEM:BOOTINFO MEM:CRASH
                     IMAGE_MAP:SPACE MAP:BOOTINFO INSTALL:BUDGET INSTALL:GROUP INSTALL:TIME_PAGE
                     INSTALL:CRASH BOOTINFO:BOOTINFO THREAD:THREAD].freeze
  # What the outer budget pays for (design-system.md, "Where each object is charged").
  OUTER_KEEPS = %w[OUTER CRASH SYS_BUDGET SYS_SIDE DOM_SIDE SYS_BELL DOM_BELL].freeze

  OK_CASES = %w[ok_request ok_configured ok_partial partial_connections_full env_ok spaces_ok
                services_room services_request narrow_share_configured limits_reserved_cleared].freeze
  OTHER_CASES = { 'quota_full' => ELIMIT, 'table_full' => ELIMIT, 'connections_full' => ELIMIT,
                  'principal_memory' => ENOMEM, 'ending' => EBUSY }.freeze
  EINVAL_CASES = %w[id_zero id_system id_last id_in_use unknown_flag secret unknown_principal
                    configured_row_out partial_row_out runtime_out runtime_file runtime_bad
                    release_past_end release_empty release_system release_sealed release_image release_wraps
                    memory_zero memory_unaligned outer_small lane_small lane_large connections_over
                    strings_long strings_wrap args_no_nul env_no_nul limits_ceiling
                    limits_frame_zero grant_cpus grant_empty grant_rate grant_ceiling grant_period grant_quota
                    grant_padding spaces_no_flag spaces_over services_over services_outside
                    narrow_share_request configured_outside configured_ceiling configured_flags].freeze

  # One-line edits of the core, each a failure the driver must catch.
  MUTANTS = {
    'principal ceiling not checked on its own' =>
      ["!dom_limits_within(&config->ceiling_limits,\n\t    &config->ceiling_limits) ||\n", ""],
    'principal counts kept from the configuration' => ["\trecord->carved = 0;\n", ""],
    'crash area charged to the principal' =>
      [".obj = ERX_DOM_OBJ_CRASH, .budget = ERX_DOM_OBJ_OUTER,\n",
       ".obj = ERX_DOM_OBJ_CRASH, .budget = ERX_DOM_OBJ_PRINCIPAL_BUDGET,\n"],
    'install without a grants row' => ['if (row->obj == step->obj && row->target == step->target &&',
                                     'if (row->target == step->target &&'],
    'undo forgets the first carve' => ['for (uint32_t index = applied; index > 0; index--)',
                                       'for (uint32_t index = applied; index > 1; index--)'],
    'charge check accepts the principal' => ['bool charged = dom_carved_budget(made, step->budget);',
                                             "bool charged = dom_carved_budget(made, step->budget) ||\n\t    step->budget == ERX_DOM_OBJ_PRINCIPAL_BUDGET;"],
    'reserve predicate drops the reserve' => ['uint64_t keep = DOM_MILLI - view->system_reserve;',
                                              'uint64_t keep = DOM_MILLI;'],
    'quota off by one' => ['principal->domains >= principal->domains_max)',
                           'principal->domains > principal->domains_max)'],
    'configured grant not fitted to system' =>
      ["if (!dom_grant_fits(&spec->grant, &view->system_grant) ||\n\t\t    !dom_system_reserve",
       'if (!dom_system_reserve'],
    'request strings tail kept' => ['memset(spec->strings + used, 0, sizeof(spec->strings) - used);', '(void)used;'],
    'record forgets the principal domain count' => ["\tprincipal->domains++;\n", ''],
    'record skips the reserve' => ["\tif (spec->origin.kind == ERX_DOM_CONFIGURED &&\n\t    !dom_system_reserve(view, &spec->grant))\n\t\treturn (ERX_EINVAL);\n", ''],
    'record forgets the grant' => ["\tdom->grant = spec->grant;\n", ''],
    'reserve counts every origin' => ["\tif (dom->origin.kind != ERX_DOM_CONFIGURED)\n\t\treturn (false);\n", ''],
    'reserve counts an ended domain' => ["\tcase ERX_DOM_RUNNING:\n\t\treturn (true);\n\tcase ERX_DOM_FREE:\n\tcase ERX_DOM_ENDED:\n",
                                         "\tcase ERX_DOM_RUNNING:\n\tcase ERX_DOM_ENDED:\n\t\treturn (true);\n\tcase ERX_DOM_FREE:\n"],
    'record overwrites a taken slot' => ["plan->slot >= view->max_domains ||\n\t    view->domains[plan->slot].id != 0)\n",
                                       "plan->slot >= view->max_domains)\n"]
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-dom-core-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, CORE), name: 'dom-core')
  end

  def test_every_failed_step_is_undone_and_the_end_keeps_only_the_outer_budget
    lines = run_driver(driver, 'explore')
    assert_empty lines.grep(/\AFAIL/), 'a failed creation left something behind'
    assert_match(/\Aexplore variants=4 applied=\d+ undone=\d+ failures=0\z/, lines.last)
    steps = lines.grep(/\Asteps /).to_h { |line| line.split.then { |_, name, *rest| [name, rest] } }
    assert_equal REQUEST_STEPS, steps.fetch('request')
    assert_equal PARTIAL_STEPS, steps.fetch('partial'), 'a partial-boot domain has no connection'
    assert_equal steps.fetch('request-spaces-jit'), steps.fetch('configured')
    assert_includes steps.fetch('configured'), 'INSTALL:SPACES_GROUP'
    after = lines.grep(/\Aafter-destroy /).to_h { |line| line.split.then { |_, name, *rest| [name, rest] } }
    %w[request request-spaces-jit configured].each { |name| assert_equal OUTER_KEEPS, after.fetch(name) }
    assert_equal %w[OUTER CRASH], after.fetch('partial')
  end

  # erx_dom_principal's validation: the record keeps the configuration with
  # its counts zeroed, and each broken field has its status. A domain quota
  # of 0 is a principal holding no domain, which the library admits.
  PRINCIPAL_CASES = {
    'ok' => '0 number=2 carved=0 domains=0 same=1', 'number_taken' => '-11',
    'number_zero' => '-1', 'memory_zero' => '-1', 'memory_unaligned' => '-1', 'share_empty' => '-1',
    'share_padding' => '-1', 'domains_zero' => '0 number=2 carved=0 domains=0 same=1', 'default_over' => '-1', 'default_frame_zero' => '-1',
    'ceiling_frame_zero' => '-1', 'ceiling_frame_over' => '-1', 'ceiling_reserved' => '-1'
  }.freeze

  def test_every_principal_refusal_has_its_status
    results = run_driver(driver, 'principal').to_h { |line| line.split(' ', 3).then { |_, name, rest| [name, rest] } }
    assert_equal PRINCIPAL_CASES, results
  end

  def test_every_refusal_has_its_status
    results = run_driver(driver, 'cases').to_h { |line| line.split.then { |_, name, status| [name, Integer(status)] } }
    expected = OK_CASES.to_h { |name| [name, 0] }.merge(OTHER_CASES)
                       .merge(EINVAL_CASES.to_h { |name| [name, EINVAL] })
    assert_equal expected.keys.sort, results.keys.sort, 'the driver and the test name the same cases'
    expected.each { |name, status| assert_equal status, results.fetch(name), name }
  end

  # erx_dom_plan_record: the record, the principal's domains and carved bytes, the
  # built configured records keeping their grant, the next connection number and the plan's connection row after
  # each record. Recorded plans are what the next plan sees, so the fourth domain
  # is past the quota of three; a plan that no longer fits leaves the view as it was.
  RECORDS = {
    'configured' => '0 id=6 state=2 labels=1 connection=1 principal=1,5242880 services=1 next=2 row=1,4,6',
    'configured_again' => '0 id=7 state=2 labels=1 connection=2 principal=2,10485760 services=2 next=3 row=2,4,7',
    'partial' => '0 id=8 state=2 labels=0 connection=0 principal=3,11599872 services=2 next=3 row=-',
    'quota_spent' => ELIMIT.to_s,
    'twice' => '-1 id=6 state=2 labels=1 connection=1 principal=1,5242880 services=1 next=2 row=1,4,6',
    'slot_taken' => '-1 id=9 state=0 labels=0 connection=0 principal=0,0 services=0 next=1 row=0,0,0',
    'not_next' => '-1 id=0 state=0 labels=0 connection=0 principal=0,0 services=0 next=2 row=0,0,0',
    'unknown_principal' => '-1 id=0 state=0 labels=0 connection=0 principal=0,0 services=0 next=1 row=0,0,0',
    'carve_overflow' => '-1 id=0 state=0 labels=0 connection=0 principal=0,18446744073709551615 services=0 next=1 row=0,0,0',
    'restart_living' => EINVAL.to_s,
    'restart_running' => EINVAL.to_s,
    'restart_ended' => '0',
    'restart_retired' => '0 id=0 principal=0,0',
    'restart_stale' => EINVAL.to_s,
    'restart_stale_fits' => '0'
  }.freeze

  def test_each_record_moves_the_view_as_the_domain_then_lives
    results = run_driver(driver, 'record').to_h { |line| line.split(' ', 3).then { |_, name, rest| [name, rest] } }
    assert_equal RECORDS, results
  end

  # The planning entries build the specification themselves: what a
  # request leaves out is the principal's default, and the origin, the
  # version, the crash area, the system lane and the CPU parent are the
  # constructor's whatever the request says.
  def test_constructors_own_the_origin_and_fill_defaults
    lines = run_driver(driver, 'seeded').grep(/\Actor /)
    assert_includes lines, 'ctor given_atoms 0 5000 1024', 'atoms given, processes the default'
    assert_includes lines, 'ctor spans 3 131072', 'the slice maps its files\' pages; the reader holds the reserve'
    %w[unknown_mask null_limits unknown_principal configured_row_out partial_row_out].each do |name|
      assert_includes lines, "ctor #{name} #{EINVAL}", name
    end
    assert_includes lines, 'ctor request_owned 0 1 1 4294967295 16384 16384 2 0',
                    'a forged origin and library fields are overwritten; the strings tail is zeroed'
    assert_includes lines, 'ctor configured_owned 0 2 0 1', 'a configured domain goes under system'
    assert_includes lines, 'ctor partial_owned 0 3 0 4294967295', 'a partial-boot domain has no connection row'
  end

  # A7: a plan that installs a foreign gate, or more rights than its grants
  # row, or charges an object outside the plan's budgets, fails the check.
  def test_seeded_plans_fail_the_check
    lines = run_driver(driver, 'seeded').grep(/\Aseeded /)
    assert_includes lines, 'seeded valid 0'
    %w[foreign_gate extra_right spaces_right principal_charge out_of_order obj_range].each do |name|
      assert_includes lines, "seeded #{name} #{EINVAL}", name
    end
  end

  def test_each_mutant_is_caught
    MUTANTS.each do |name, (from, to)|
      text = File.read(File.join(@root, CORE))
      assert_equal 1, text.scan(from).size, "the #{name} seed no longer applies"
      mutated = File.join(@directory, "mutant-#{name.tr(' ', '-')}.c")
      File.write(mutated, text.sub(from) { to })
      mutant = build_driver(mutated, name: "mutant-#{name.tr(' ', '-')}")
      lines = MODES.flat_map { |mode| run_driver(mutant, mode, check: false) }
      refute_equal clean_lines, lines, "mutant survived: #{name}"
    end
  end

  private

  MODES = %w[explore cases seeded principal record].freeze

  def clean_lines = @clean_lines ||= MODES.flat_map { |mode| run_driver(driver, mode) }

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-Wswitch-enum',
                 '-pedantic', '-O1', '-g', *@flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), core, File.join(@root, 'liberx/system/dom_life.c'),
                 File.join(@root, 'liberx/erx_lane.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'test/fixtures/dom_core_driver.c'), '-o', output],
                name: "dom-core-#{name}", deadline: 120)
    output
  end

  # A mutant may exit non-zero; its output still differs from the core's.
  def run_driver(path, mode, check: true)
    record = @runner.run([path, mode], name: "dom-core-run-#{mode}", deadline: 60)
    File.readlines(record.fetch('log'), chomp: true)
  rescue Erx::CommandError => error
    raise if check

    File.readlines(error.result.fetch('log'), chomp: true)
  end
end
