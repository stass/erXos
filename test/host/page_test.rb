# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the grace tracker (kernel/core/grace.c) and the page funnel
# (kernel/core/page.c), built with the budget core, through
# test/fixtures/page_driver.c, which checks the funnel's identity, the
# released list's order and the locks' order after every command.
#
# The tracker is judged twice over: line by line against GraceModel, and
# by a safety check that knows nothing of periods: an item is mature only
# once every CPU active at its retirement has reported since. The funnel is
# judged by its counts, predicted per reserve, and by the driver's checks.
class PageTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_PAGE_SEED', '20261107'))
  NARROW_LAST = 7
  CPUS = 4
  GRACE_SCRIPTS = 300
  FUNNEL_SCRIPTS = 60
  PAGES = 40
  EINVAL = -1
  ENOMEM = -6
  ESTALE = -2
  DONE, MORE, WAIT, CANCELLED = 1, 2, 3, 4
  TRAPS = [Signal.list.fetch('TRAP'), Signal.list.fetch('ILL'),
           128 + Signal.list.fetch('TRAP'), 128 + Signal.list.fetch('ILL')].freeze

  # The tracker as the design states it: a retire stamps the period after
  # the current one, starting it over the online CPUs when none is in
  # progress and requesting it otherwise; a period completes when every CPU
  # it awaits has reported or gone offline.
  class GraceModel
    Trap = Class.new(StandardError)
    attr_reader :current, :completed, :awaited, :online, :pending
  
    def initialize(last)
      @last = last
      @current = @completed = @awaited = @online = 0
      @pending = false
    end
  
    def join(cpu) = @online |= bit(cpu)
  
    def leave(cpu)
      @online &= ~bit(cpu)
      @awaited &= ~bit(cpu)
      settle
    end
  
    def retire
      raise Trap if @online.zero? || @current == @last
  
      stamp = @current + 1
      if @current == @completed
        @current = stamp
        @awaited = @online
      else
        @pending = true
      end
      stamp
    end
  
    def report(cpu)
      return false if @current == @completed || (@awaited & bit(cpu)).zero?
  
      @awaited &= ~bit(cpu)
      settle
    end
  
    def mature?(stamp) = @completed >= stamp
  
    private
  
    def bit(cpu)
      raise Trap if cpu >= 64
  
      1 << cpu
    end
  
    def settle
      done = false
      while @current != @completed && @awaited.zero?
        @completed = @current
        done = true
        break unless @pending
  
        @current += 1
        @awaited = @online
        @pending = false
      end
      done
    end
  end
  
  # One-line edits of the cores, each a failure a test here must catch.
  MUTANTS = {
    'a retire stamps the current count' =>
      ['kernel/core/grace.c', "stamp = tracker->current + 1;\n", "stamp = tracker->current;\n"],
    'maturity by a modular comparison' =>
      ['kernel/core/grace.c', "return (atomic_load_explicit(&tracker->completed,\n\t    memory_order_acquire) >= stamp);",
       "return (((atomic_load_explicit(&tracker->completed,\n\t    memory_order_acquire) - stamp) &\n" \
       "\t    ERX_GRACE_COUNT_LAST) < (ERX_GRACE_COUNT_LAST >> 1) + 1);"],
    'the count runs past its last value' =>
      ['kernel/core/grace.c', "\tif (tracker->online == 0 || tracker->current == ERX_GRACE_COUNT_LAST)\n\t\t__builtin_trap();\n\tstamp",
       "\tif (tracker->online == 0)\n\t\t__builtin_trap();\n\tstamp"],
    'a release refunds before it appends' =>
      ['kernel/core/page.c',
       "\tif (pages > 0)\n\t\treleased_append(released, &batch);\n" \
       "\t/* Checked above, so the refund, a decrease, cannot be refused. */\n" \
       "\tif (erx_reserve_refund(reserve, used, from_pool, effects) != 0)\n\t\t__builtin_trap();\n",
       "\tif (erx_reserve_refund(reserve, used, from_pool, effects) != 0)\n\t\t__builtin_trap();\n" \
       "\tif (pages > 0)\n\t\treleased_append(released, &batch);\n"],
    'a backing does not wait for its hand' =>
      ['kernel/core/page.c', "if (!erx_grace_mature(released->tracker, backing->newest))", 'if (0)'],
    'the free step takes immature pages' =>
      ['kernel/core/page.c', "(which == ERX_RELEASED_MATURE &&\n", "(which == 0 &&\n"]
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-page-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported page-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @rng = Random.new(SEED)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver = @driver ||= build_driver(name: 'page')
  def narrow = @narrow ||= build_driver(name: 'page-narrow', last: NARROW_LAST)

  # An item retired while no period is in progress starts a period that
  # awaits every active CPU, and matures only when the last has reported.
  def test_an_item_retired_while_no_period_runs_waits_for_every_cpu
    assert_equal %w[7 1 0 0 0 1 1], run_lines(driver, ['cpus 7', 'retire', 'report 0', 'report 2', 'mature 1',
                                                     'report 1', 'mature 1'])
  end

  # A CPU that has reported for the period in progress may take a pointer to
  # the next item before it is retired, so that period's completion proves
  # nothing about it: the item waits for the next period, which hears from
  # that CPU again. A retire that stamps the current count lets it mature
  # while the CPU still holds its pointer.
  def test_an_item_retired_after_a_cpus_report_waits_for_the_next_period
    script = ['cpus 3', 'retire', 'report 0', 'retire', 'report 1', 'mature 2', 'grace', 'report 1', 'mature 2',
              'report 0', 'mature 2']
    assert_equal ['3', '1', '0', '2', '1', '0', '2 1 3 3 0', '0', '0', '1', '1'], run_lines(driver, script)
    assert_safe(script, run_lines(driver, script))
  end

  def test_random_tracker_scripts_agree_with_the_model_and_are_safe
    scripts = Array.new(GRACE_SCRIPTS) { grace_script(length: 60) }
    outputs = batch_lines(driver, scripts)
    scripts.zip(outputs).each do |script, lines|
      assert_equal predict(script, last: 2**64 - 1), lines, script.join('; ')
      assert_safe(script, lines)
      current, completed, _awaited, _online, pending = lines.last.split.map { |field| Integer(field) }
      assert_equal [current, 0], [completed, pending], "a stamp did not mature: #{script.join('; ')}"
    end
  end

  # A CPU that goes offline counts as its report, and the period a
  # requested one starts on completion awaits only the CPUs still online,
  # so a CPU leaving with its report never leaves a period waiting for it.
  def test_a_cpu_going_offline_never_stalls_a_period
    assert_equal %w[3 1 2 0 1 1 1] + ['2 2 0 1 0'],
                 run_lines(driver, ['cpus 3', 'retire', 'retire', 'report 0', 'leave 1', 'report 0', 'mature 2',
                                    'grace'])
    assert_equal %w[1 1 1 1] + ['1 1 0 0 0'], run_lines(driver, ['cpus 1', 'retire', 'leave 0', 'mature 1', 'grace'])
  end

  # Built with a narrow count, the tracker reaches its last value: every
  # decision before it agrees with the model, and the retire that would
  # need a period beyond it traps.
  def test_the_narrow_count_ends_in_a_trap_and_decides_right_until_then
    10.times do
      script = grace_script(length: 400, reports: 3)
      expected = predict(script, last: NARROW_LAST)
      assert_operator expected.size, :<, script.size, 'the script never reaches the last value'
      assert_equal expected, run_lines(narrow, script.take(expected.size))
      assert_includes TRAPS, trapped(narrow, script.take(expected.size + 1))
    end
  end

  def test_broken_contracts_trap
    assert_includes TRAPS, trapped(driver, ['cpus 0', 'retire'])
    assert_includes TRAPS, trapped(driver, ['report 64'])
    assert_includes TRAPS, trapped(driver, ['pages 4', 'reserve 0', 'take 0'])
    assert_includes TRAPS, trapped(driver, ['join 64'])
  end

  # A release appends its batch, stamped by one retire, before it refunds:
  # the driver checks the list from inside the budget's lock, and the next
  # charge, admitted on the refund, backs itself with exactly those pages
  # and waits for their period.
  def test_a_release_appends_before_it_refunds_and_the_next_charge_waits
    script = ['cpus 3', 'pages 8', 'reserve 0', 'reserve 1', 'charge 0 8', 'step 0 0', 'take 0', 'take 0',
              'charge 1 1', 'release 0 2 2', 'list', 'state 0', 'charge 1 4', 'step 1 0', 'free', 'list',
              'report 0', 'report 1', 'step 1 0', 'state 1']
    lines = run_lines(driver, script)
    assert_equal ['3', '8', '0', '1', '0', DONE.to_s, '0', '1', ENOMEM.to_s, '0', '4 0:1 1:1 2:1 3:1',
                  '4 4 4 0 0', '0', WAIT.to_s, '0', '0', '0', '1', DONE.to_s, '4 4 4 0 0'], lines
  end

  # A backing that finds an existence lock closed takes nothing more, puts
  # its hand in the pool once mature, and cancels the rest.
  def test_a_closed_backing_installs_its_hand_and_cancels_the_rest
    script = ['cpus 1', 'pages 140', 'reserve 0', 'reserve 1', 'charge 0 140', 'step 0 0', 'step 0 0', 'step 0 0',
              'release 0 64 0', 'release 0 64 0', 'charge 1 100', 'step 1 0', 'state 1', 'step 1 1', 'state 1',
              'report 0', 'step 1 1', 'state 1', 'charge 1 0', 'step 1 1', 'state 1']
    assert_equal ['1', '140', '0', '1', '0', MORE.to_s, MORE.to_s, DONE.to_s, '0', '0', '0', WAIT.to_s,
                  '100 0 0 0 64', WAIT.to_s, '100 0 0 0 64', '1', CANCELLED.to_s, '64 64 64 0 0', '0',
                  CANCELLED.to_s, '64 64 64 0 0'], run_lines(driver, script)
  end

  # K6's verification: a 129-page charge closed at each boundary between
  # its parts keeps what its earlier parts took, cancels the rest, and,
  # once the reserve's pages are released, leaves the root as it was.
  def test_a_charge_closed_at_every_part_boundary_returns_the_rest
    (0..2).each do |boundary|
      steps = Array.new(boundary) { 'step 0 0' } + ['step 0 1']
      kept = [64 * boundary, 129].min
      releases = Array.new(kept.fdiv(64).ceil) { |i| "release 0 #{[64, kept - (64 * i)].min} 0" }
      script = ['cpus 1', 'pages 129', 'reserve 0', 'charge 0 129', *steps, 'state 0', *releases,
                'state 0', 'charge 0 129']
      lines = run_lines(driver, script)
      assert_equal CANCELLED.to_s, lines[4 + boundary], "boundary #{boundary}"
      assert_equal "#{kept} #{kept} #{kept} 0 0", lines[5 + boundary], "boundary #{boundary}"
      assert_equal ['0'] * releases.size, lines[6 + boundary, releases.size], "boundary #{boundary}"
      assert_equal '0 0 0 0 0', lines[-2], "boundary #{boundary}"
      # The whole root is charged again: every page came back to it.
      assert_equal '0', lines[-1], "boundary #{boundary}: the root did not get its pages back"
    end
  end
  
  def test_a_release_beyond_what_the_reserve_holds_changes_nothing
    lines = run_lines(driver, ['pages 70', 'reserve 0', 'charge 0 70', 'step 0 0', 'step 0 0', 'release 0 65 0',
                               'release 0 71 0', 'state 0', 'list'])
    assert_equal ['70', '0', '0', MORE.to_s, DONE.to_s, EINVAL.to_s, EINVAL.to_s, '70 70 70 0 0', '0'], lines
  end

  # Random charges, steps, takes, releases, reports and free steps over two
  # reserves keep the identity and the list's order (the driver's checks),
  # and every status and count is the one the reserves' accounting
  # predicts.
  def test_random_funnel_scripts_keep_the_identity_and_the_counts
    scripts, predictions = Array.new(FUNNEL_SCRIPTS) { funnel_script(length: 80) }.transpose
    batch_lines(driver, scripts).zip(predictions, scripts).each do |lines, expected, script|
      refute(lines.any? { |line| line.start_with?('!') }, script.join('; '))
      expected.each { |index, value| assert_equal value, lines[index], "line #{index} of #{script.join('; ')}" }
    end
  end

  def test_every_mutant_is_caught
    MUTANTS.each do |name, (file, original, replacement)|
      program = build_driver(name: "mutant-#{name.tr(' ', '-')}", mutant: [file, original, replacement],
                             last: file.end_with?('grace.c') ? NARROW_LAST : nil)
      assert mutant_caught?(program), "mutant not caught: #{name}"
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  SOURCES = %w[kernel/core/grace.c kernel/core/page.c kernel/core/budget.c].freeze
  HEADERS = %w[kernel/core/grace_impl.h kernel/core/page_impl.h kernel/core/budget_impl.h].freeze

  # The driver includes the private headers by their plain names from the
  # cores' directory; a mutant's copy of the cores finds its own beside it.
  def build_driver(name:, last: nil, mutant: nil)
    sources = SOURCES.map { |source| File.join(@root, source) }
    core_dir = File.join(@root, 'kernel/core')
    if mutant
      core_dir = File.join(@directory, "source-#{name}")
      FileUtils.mkdir_p(core_dir)
      HEADERS.each { |header| FileUtils.cp(File.join(@root, header), core_dir) }
      file, original, replacement = mutant
      text = File.read(File.join(@root, file))
      assert_equal 1, text.scan(original).size, "mutant #{name} must edit exactly one place"
      sources = SOURCES.map { |source| File.join(core_dir, File.basename(source)) }
      SOURCES.each { |source| FileUtils.cp(File.join(@root, source), core_dir) }
      File.write(File.join(core_dir, File.basename(file)), text.sub(original, replacement))
    end
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-DERX_HOST',
                 *(last ? ["-DERX_GRACE_COUNT_LAST=#{last}"] : []), *@sanitizer_flags,
                 *Erx::Generated.include_flags(root: @root), '-I', File.join(@root, 'include'), '-I', core_dir,
                 *sources, File.join(@root, 'test/fixtures/page_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def write_script(script)
    input = File.join(@directory, "script-#{@rng.rand(1 << 62)}.txt")
    File.write(input, script.map { |line| "#{line}\n" }.join)
    input
  end

  # The driver's "=" lines and its "!" checks, in order; [] when it trapped.
  def run_lines(program, script)
    record = @runner.run([program, write_script(script)], name: 'page-driver', deadline: 300)
    File.read(record.fetch('log')).lines.map(&:chomp).grep(/\A[=!] /).map { |line| line.delete_prefix('= ') }
  rescue Erx::CommandError => error
    File.read(error.result.fetch('log')).lines.map(&:chomp).grep(/\A! /)
  end

  # Runs scripts one after another in one driver process each; split back
  # by script. Each script starts with a fresh driver, as the tracker and
  # the pages are the process's.
  def batch_lines(program, scripts) = scripts.map { |script| run_lines(program, script) }

  def trapped(program, script)
    @runner.run([program, write_script(script)], name: 'page-trap', deadline: 60)
    nil
  rescue Erx::CommandError => error
    error.result['signal'] || error.result['exit_status']
  end

  # A tracker script: CPUs join and leave (one stays online), items are
  # retired, online CPUs report, and maturity is asked of stamps handed out
  # so far. It ends with two reports from every online CPU, after which
  # no period is in progress or requested, so every stamp is mature.
  def grace_script(length:, reports: 2)
    online = 0b0111
    issued = 0
    script = ["cpus #{online}"]
    length.times do
      case @rng.rand(10)
      when 0
        cpu = @rng.rand(CPUS)
        if online[cpu] == 1 && online.to_s(2).count('1') > 1
          script << "leave #{cpu}"
          online &= ~(1 << cpu)
        elsif online[cpu].zero?
          script << "join #{cpu}"
          online |= 1 << cpu
        end
      when 1, 2
        issued += 1
        script << 'retire'
      when 3..(3 + reports)
        script << "report #{online_cpu(online)}"
      else
        script << "mature #{1 + @rng.rand(issued + 2)}"
      end
    end
    2.times { (0...CPUS).each { |cpu| script << "report #{cpu}" if online[cpu] == 1 } }
    script << 'grace'
  end
  
  def online_cpu(online) = (0...CPUS).select { |cpu| online[cpu] == 1 }.sample(random: @rng)
  
  # The model's lines for script, up to the command that traps.
  def predict(script, last:)
    model = GraceModel.new(last)
    script.each_with_object([]) do |line, lines|
      name, arg = line.split
      lines << case name
               when 'cpus' then set_online(model, Integer(arg)).to_s
               when 'join' then model.join(Integer(arg)) && arg
               when 'leave' then model.leave(Integer(arg)) ? '1' : '0'
               when 'retire' then model.retire.to_s
               when 'report' then model.report(Integer(arg)) ? '1' : '0'
               when 'mature' then model.mature?(Integer(arg)) ? '1' : '0'
               when 'grace'
                 "#{model.current} #{model.completed} #{model.awaited} #{model.online} #{model.pending ? 1 : 0}"
               end
    rescue GraceModel::Trap
      break lines
    end
  end
  
  # The driver's cpus command: join and leave, lowest CPU first.
  def set_online(model, mask)
    64.times do |cpu|
      if mask[cpu] == 1 && model.online[cpu].zero?
        model.join(cpu)
      elsif mask[cpu].zero? && model.online[cpu] == 1
        model.leave(cpu)
      end
    end
    mask
  end
  
  # The safety check: whenever the tracker calls a stamp mature, every CPU
  # online when an item with that stamp was retired has reported or left
  # since.
  def assert_safe(script, lines)
    online = 0
    retired = [] # [stamp, cpus that must still report]
    script.zip(lines).each do |line, output|
      break if output.nil?
  
      name, arg = line.split
      case name
      when 'cpus'
        left = online & ~Integer(arg)
        retired.each { |item| item[1] &= ~left }
        online = Integer(arg)
      when 'join' then online |= 1 << Integer(arg)
      when 'retire' then retired << [Integer(output), online]
      when 'report', 'leave'
        retired.each { |item| item[1] &= ~(1 << Integer(arg)) }
        online &= ~(1 << Integer(arg)) if name == 'leave'
      when 'mature'
        next unless output == '1'
  
        owing = retired.select { |stamp, cpus| stamp <= Integer(arg) && !cpus.zero? }
        assert_empty owing, "stamp #{arg} called mature while a CPU may hold an item: #{script.join('; ')}"
      end
    end
  end
  
  # A funnel script over two reserves on a root of PAGES, with the lines
  # whose values the reserves' accounting fixes: each charge's status, and
  # each reserve's counts at the end. A backing runs to its end within the
  # script (a step, then every CPU's report twice so whatever it took
  # matures, until the last part); one in six is closed at its first step,
  # which cancels the whole charge.
  def funnel_script(length:)
    script = ['cpus 3', "pages #{PAGES}", 'reserve 0', 'reserve 1']
    expected = {}
    counts = Array.new(2) { { charged: 0, pooled: 0, used: 0 } }
    length.times do
      r = @rng.rand(2)
      c = counts[r]
      case @rng.rand(6)
      when 0
        n = @rng.rand(1..30)
        script << "charge #{r} #{n}"
        if counts.sum { |x| x[:charged] } + n > PAGES
          expected[script.size - 1] = ENOMEM.to_s
          next
        end

        expected[script.size - 1] = '0'
        closed = @rng.rand(6).zero?
        script << "step #{r} #{closed ? 1 : 0}"
        3.times { script.push('report 0', 'report 1', 'report 0', 'report 1', "step #{r} 0") }
        next if closed

        c[:charged] += n
        c[:pooled] += n
      when 1, 2
        next if c[:pooled].zero?

        script << "take #{r}"
        c[:pooled] -= 1
        c[:used] += 1
      when 3
        pooled = @rng.rand(c[:pooled] + 1)
        used = @rng.rand(c[:used] + 1)
        script << "release #{r} #{pooled} #{used}"
        expected[script.size - 1] = '0'
        c[:pooled] -= pooled
        c[:used] -= used
        c[:charged] -= pooled + used
      when 4 then script << "report #{@rng.rand(2)}"
      else script << "reap #{@rng.rand(1..64)}"
      end
    end
    2.times do |r|
      script << "state #{r}"
      c = counts[r]
      expected[script.size - 1] = "#{c[:charged]} #{c[:charged]} #{c[:pooled]} #{c[:used]} 0"
    end
    [script, expected]
  end

  # Whether a judging check fails against program: the tracker's scripted
  # cases, the narrow run, the release's order or the backing's waits.
  def mutant_caught?(program)
    scenario = ['cpus 3', 'retire', 'report 0', 'retire', 'report 1', 'mature 2', 'report 1', 'mature 2']
    return true unless run_lines(program, scenario) == ['3', '1', '0', '2', '1', '0', '0', '0']

    script = grace_script(length: 400, reports: 3)
    expected = predict(script, last: NARROW_LAST)
    return true unless run_lines(program, script.take(expected.size)) == expected
    return true unless TRAPS.include?(trapped(program, script.take(expected.size + 1)))

    release = ['cpus 3', 'pages 8', 'reserve 0', 'reserve 1', 'charge 0 8', 'step 0 0', 'release 0 4 0',
               'reap 64', 'free', 'charge 1 4', 'step 1 0', 'report 0', 'report 1', 'step 1 0']
    run_lines(program, release) != ['3', '8', '0', '1', '0', DONE.to_s, '0', '0', '0', '0', WAIT.to_s, '0', '1',
                                    DONE.to_s]
  end
end
