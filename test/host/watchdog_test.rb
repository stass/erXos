# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'set'
require 'tmpdir'
require_relative '../fixtures/watchdog_model'
require_relative '../../tools/lib/erx/runner'

# Judges kernel/core/watchdog.c. erx_watchdog_step is explored exhaustively
# against WatchdogModel: every event kind at every time of a small time
# domain, from every reachable state, in both modes. The clock never goes
# back, so the reachable set is finite and the search runs until it is
# closed, which it must be within DEPTH_MAX events.
# Hand cases pin the deadline boundaries and the clock's last instants, and
# seeded one-line mutants of the core must each fail the exploration. The
# erx.watchdog= parser is checked against the design's bounds, every
# malformed shape, and every short string over a small alphabet.
class WatchdogTest < Minitest::Test
  S = WatchdogModel::NS_PER_S
  MAX = WatchdogModel::CLOCK_MAX
  CAUSE = WatchdogModel::WATCHDOG_CAUSE
  PANIC = WatchdogModel::PANIC_CAUSE
  CODEC = WatchdogModel::CODEC
  Config = WatchdogModel::Config
  Spec = WatchdogModel::Spec

  PERIOD_MIN = CODEC.constant('watchdog_period_min')
  PERIOD_MAX = CODEC.constant('watchdog_period_max')
  DEADLINE_PERIODS_MIN = CODEC.constant('watchdog_deadline_periods_min')
  DEADLINE_MAX = CODEC.constant('watchdog_deadline_max')
  BOOT_MAX = CODEC.constant('watchdog_boot_max')
  DEFAULTS = [CODEC.constant('watchdog_period_default'), CODEC.constant('watchdog_deadline_default'),
              CODEC.constant('watchdog_boot_default')].freeze

  # Exploration bounds. Times are whole seconds 0..8 and the clock's last
  # five seconds, each exactly and one nanosecond either side. Every
  # deadline that falls on a whole second is met at, one before and one
  # after; deadlines off a whole second are met at and after. The last
  # instants make the deadline arithmetic overflow.
  DEPTH_MAX = 16
  FAILURES_KEPT = 100
  TIMES = ((0..8).flat_map { |second| [second * S - 1, second * S, second * S + 1] } +
           (0..4).flat_map { |second| [MAX - second * S - 1, MAX - second * S, MAX - second * S + 1] })
          .select { |time| time.between?(0, MAX) }.uniq.sort.freeze
  KINDS = %i[start pet tick].freeze
  # D = 2P and B > D; and B = D, the smallest boot deadline.
  CONFIGS = [Config.new(period_s: 1, deadline_s: 2, boot_s: 3), Config.new(period_s: 1, deadline_s: 2, boot_s: 2)].freeze

  State = Data.define(:phase, :since_ns, :deadline_ns)
  Answer = Data.define(:next_state, :action, :cause, :uptime_ns, :since_pet_ns)
  Node = Data.define(:state, :spec, :now_ns)
  Edge = Data.define(:node, :kind, :now_ns)
  Exploration = Data.define(:failures, :covered, :nodes, :edges, :depth, :closed)
  Parsed = Data.define(:status, :config, :reason)

  UNARMED = State.new(phase: :unarmed, since_ns: 0, deadline_ns: 0)

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-watchdog-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported watchdog-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = build_driver(File.join(@root, 'kernel/core/watchdog.c'), name: 'watchdog')
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_exploration_agrees_with_the_model_in_every_reachable_state
    %i[normal det].product(CONFIGS).each do |mode, config|
      result = explore(@driver, mode: mode, config: config)
      $stdout.puts("watchdog_test: #{mode} #{config.to_h}: #{result.nodes} states, #{result.edges} events, " \
                   "closed after #{result.depth} events")
      assert result.closed, "#{mode} #{config.to_h}: states still unexplored after #{DEPTH_MAX} events"
      assert_empty result.failures, "#{mode} #{config.to_h}: #{result.failures.first(5).join('; ')}"
      next unless mode == :normal

      missing = required_cases - result.covered
      assert_empty missing, "#{config.to_h}: the exploration never reached #{missing.to_a.inspect}"
    end
  end

  def test_deterministic_mode_never_ends_and_accepts_pets
    result = explore(@driver, mode: :det, config: CONFIGS.first)
    refute(result.covered.any? { |covered_case| covered_case.last == :end }, 'deterministic mode ended the machine')
    off = State.new(phase: :off, since_ns: 0, deadline_ns: 0)
    assert_equal [off, :none], step_one(UNARMED, :start, 0, mode: :det).then { [_1.next_state, _1.action] }
    assert_equal [off, :none], step_one(off, :pet, MAX, mode: :det).then { [_1.next_state, _1.action] }
    assert_equal :reload, step_one(off, :tick, MAX, mode: :det).action
  end

  # Seeded mutants of the core, each one edit; the exploration and the
  # model alone must reject every one, in the mode it names, and accept the
  # unedited core.
  def test_exploration_rejects_mutants_of_the_core
    mutants = {
      'a tick extends the deadline instead of a pet' =>
        ['return (erx_watchdog_stay(state, ERX_WATCHDOG_RELOAD));',
         'return ((erx_watchdog_step_t){ .next = state->phase == ERX_WATCHDOG_ARMED ? ' \
         'erx_watchdog_arm_at(event.now_ns, config->deadline_s) : *state, .action = ERX_WATCHDOG_RELOAD });', :normal],
      'a tick at the deadline ends the machine' =>
        ["state->phase == ERX_WATCHDOG_ARMED &&\n\t\t    event.now_ns > state->deadline_ns)",
         "state->phase == ERX_WATCHDOG_ARMED &&\n\t\t    event.now_ns >= state->deadline_ns)", :normal],
      'a late pet renews the deadline' =>
        ["state->phase != ERX_WATCHDOG_ARMED ||\n\t\t    event.now_ns > state->deadline_ns)",
         'state->phase != ERX_WATCHDOG_ARMED)', :normal],
      'a pet before the start arms' =>
        ['if (state->phase != ERX_WATCHDOG_ARMED ||', 'if (state->phase == ERX_WATCHDOG_OFF ||', :normal],
      'the start arms with D instead of B' =>
        ["erx_watchdog_arm_at(event.now_ns,\n\t\t\t    config->boot_s)",
         "erx_watchdog_arm_at(event.now_ns,\n\t\t\t    config->deadline_s)", :normal],
      'a repeated start re-arms' =>
        ["if (state->phase != ERX_WATCHDOG_UNARMED)\n\t\t\treturn (erx_watchdog_stay(state, ERX_WATCHDOG_NONE));",
         'if (0) {}', :normal],
      'an overflowing deadline wraps' =>
        ["\t\tdeadline_ns = UINT64_MAX;", "\t\tdeadline_ns = since_ns + span_ns;", :normal],
      'since_pet measured from the deadline' =>
        ['step.end.since_pet_ns = now_ns - state->since_ns;', 'step.end.since_pet_ns = now_ns - state->deadline_ns;', :normal],
      'deterministic mode arms' =>
        ['if (mode == ERX_WATCHDOG_MODE_DETERMINISTIC) {', 'if (0) {', :det]
    }
    config = CONFIGS.first
    %i[normal det].each do |mode|
      assert_empty explore(@driver, mode: mode, config: config).failures, "the unedited core, #{mode} mode"
    end
    mutants.each_with_index do |(name, (original, replacement, mode)), index|
      driver = build_driver(mutant_source(name, original, replacement, index: index), name: "mutant-#{index}")
      failures = explore(driver, mode: mode, config: config).failures
      refute_empty failures, "the exploration accepted the mutant: #{name}"
      $stdout.puts("watchdog_test: mutant '#{name}' rejected; first disagreement: #{failures.first}")
    end
  end

  def test_initial_state_is_unarmed
    assert_equal ["initial unarmed 0 0\n"], run_driver(@driver, ["initial\n"])
  end

  def test_boot_deadline_applies_before_the_first_pet
    config = Config.new(period_s: 1, deadline_s: 5, boot_s: 60)
    armed = step_one(UNARMED, :start, 10 * S, config: config)
    assert_equal [:arm, State.new(phase: :armed, since_ns: 10 * S, deadline_ns: 70 * S)],
                 [armed.action, armed.next_state]
    assert_equal :reload, step_one(armed.next_state, :tick, 70 * S, config: config).action, 'a tick at B'
    ended = step_one(armed.next_state, :tick, 70 * S + 1, config: config)
    assert_equal [:end, CAUSE, 70 * S + 1, 60 * S + 1], [ended.action, ended.cause, ended.uptime_ns, ended.since_pet_ns]
  end

  def test_pets_at_one_before_at_and_after_the_deadline
    config = Config.new(period_s: 1, deadline_s: 5, boot_s: 60)
    armed = State.new(phase: :armed, since_ns: 0, deadline_ns: 60 * S)
    [[60 * S - 1, 65 * S - 1], [60 * S, 65 * S]].each do |now, deadline|
      pet = step_one(armed, :pet, now, config: config)
      assert_equal [:none, State.new(phase: :armed, since_ns: now, deadline_ns: deadline)], [pet.action, pet.next_state]
    end
    late = step_one(armed, :pet, 60 * S + 1, config: config)
    assert_equal [:none, armed], [late.action, late.next_state], 'a late pet moves nothing'
    assert_equal :end, step_one(late.next_state, :tick, 60 * S + 1, config: config).action
  end

  def test_repeated_pets_keep_extending
    pets = (1..100).flat_map { |round| [[:pet, round * 4 * S], [:tick, (round * 4 + 5) * S]] }
    answers = trace([[:start, 0], *pets, [:tick, 405 * S + 1]], config: Config.new(period_s: 1, deadline_s: 5, boot_s: 60))
    assert_equal [:arm, *(%i[none reload] * 100), :end], answers.map(&:action)
    assert_equal 5 * S + 1, answers.last.since_pet_ns, 'measured from the last pet'
  end

  def test_pet_and_tick_before_the_start_change_nothing
    assert_equal [UNARMED, :none], step_one(UNARMED, :pet, 5 * S).then { [_1.next_state, _1.action] }
    assert_equal [UNARMED, :reload], step_one(UNARMED, :tick, MAX).then { [_1.next_state, _1.action] }
  end

  def test_deadline_past_the_clock_saturates_and_never_ends
    armed = step_one(UNARMED, :start, MAX - S, config: Config.new(period_s: 1, deadline_s: 2, boot_s: 3)).next_state
    assert_equal State.new(phase: :armed, since_ns: MAX - S, deadline_ns: MAX), armed
    assert_equal :reload, step_one(armed, :tick, MAX).action
    exact = step_one(UNARMED, :start, MAX - 3 * S, config: Config.new(period_s: 1, deadline_s: 2, boot_s: 3)).next_state
    assert_equal MAX, exact.deadline_ns, 'a deadline that lands on the last instant does not saturate'
    pet = step_one(armed, :pet, MAX, config: Config.new(period_s: 1, deadline_s: 600, boot_s: 600)).next_state
    assert_equal State.new(phase: :armed, since_ns: MAX, deadline_ns: MAX), pet
  end

  # Out-of-range values are the kernel's own bug: the machine ends, and the
  # crash record says panic rather than blame the root task.
  def test_out_of_range_phase_mode_or_event_ends_the_machine_as_a_panic
    bogus = State.new(phase: :bogus, since_ns: 1, deadline_ns: 2)
    armed = State.new(phase: :armed, since_ns: 3, deadline_ns: 3 + 3 * S)
    [[bogus, :tick, :normal], [armed, :bogus, :normal], [UNARMED, :start, :bogus]].each do |state, kind, mode|
      answer = step_one(state, kind, 7, mode: mode)
      assert_equal [:end, PANIC, 7, 0, state], [answer.action, answer.cause, answer.uptime_ns, answer.since_pet_ns, answer.next_state],
                   "#{kind} in #{state.phase}, mode #{mode}"
    end
  end

  def test_defaults_are_the_designs_and_valid
    assert_equal ["default #{DEFAULTS.join(' ')}\n"], run_driver(@driver, ["default\n"])
    assert_equal [1, 5, 60], DEFAULTS
    assert_equal :ok, parse(DEFAULTS.join(',')).status
  end

  def test_parser_accepts_values_at_each_bound
    {
      "#{PERIOD_MIN},#{2 * PERIOD_MIN},#{2 * PERIOD_MIN}" => [PERIOD_MIN, 2 * PERIOD_MIN, 2 * PERIOD_MIN],
      "#{PERIOD_MAX},#{2 * PERIOD_MAX},#{BOOT_MAX}" => [PERIOD_MAX, 2 * PERIOD_MAX, BOOT_MAX],
      "1,#{DEADLINE_MAX},#{BOOT_MAX}" => [1, DEADLINE_MAX, BOOT_MAX],
      '2,7,9' => [2, 7, 9],
      '0001,005,060' => [1, 5, 60],
      "#{'0' * 100_000}3,10,20" => [3, 10, 20]
    }.then { |cases| cases.keys.zip(parse_all(cases.keys), cases.values) }.each do |value, parsed, expected|
      assert_equal [:ok, expected], [parsed.status, parsed.config], value.byteslice(0, 40)
    end
  end

  def test_parser_refuses_each_malformed_shape_with_defaults
    cases = {
      '' => :empty, ',5,60' => :empty, '1,,60' => :empty, '1,5,' => :empty,
      '1' => :fields, '1,5' => :fields, '1,5,60,7' => :fields, '1,5,60,' => :fields,
      'off' => :digit, '1,5,60 ' => :digit, ' 1,5,60' => :digit, '+1,5,60' => :digit, '-1,5,60' => :digit,
      "1,5\0,60" => :digit, "1,5,60\0" => :digit, "\0" => :digit, "1,5,6\xff" => :digit, '1;5;60' => :digit,
      '1.5,5,60' => :digit, '0x1,5,60' => :digit,
      '4294967296,5,60' => :overflow, "1,5,#{'9' * 100_000}" => :overflow, '1,99999999999,60' => :overflow,
      '4294967295,5,60' => :period, '0,5,60' => :period, "#{PERIOD_MAX + 1},600,600" => :period,
      '1,1,60' => :deadline, "10,#{2 * 10 - 1},60" => :deadline, "1,#{DEADLINE_MAX + 1},#{BOOT_MAX}" => :deadline,
      '1,5,4' => :boot, "1,5,#{BOOT_MAX + 1}" => :boot, '30,60,59' => :boot
    }.transform_keys(&:b)
    reasons = cases.keys.zip(parse_all(cases.keys)).to_h do |value, parsed|
      assert_equal [cases.fetch(value), DEFAULTS], [parsed.status, parsed.config], value.byteslice(0, 40).inspect
      [parsed.status, parsed.reason]
    end
    assert_equal 7, reasons.size, 'every refusal status is reached'
    assert_equal reasons.size, reasons.values.uniq.size, 'each refusal has its own reason'
  end

  # Every string of up to six bytes over digits, a comma, a letter and NUL
  # is accepted exactly when it is three decimal fields within the bounds,
  # with those values; every other string yields the defaults.
  def test_parser_agrees_with_the_bounds_on_every_short_string
    alphabet = ['0', '1', '6', ',', 'a', "\0"]
    values = (0..6).flat_map { |length| alphabet.repeated_permutation(length).map(&:join) }
    results = parse_all(values)
    disagreements = values.zip(results).reject do |value, parsed|
      expected = expected_config(value)
      expected ? parsed.status == :ok && parsed.config == expected : parsed.status != :ok && parsed.config == DEFAULTS
    end
    assert_empty disagreements.first(5), "#{disagreements.size} of #{values.size} strings disagree"
  end

  def test_core_builds_freestanding_for_the_target
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2',
                 '--target=aarch64-none-elf', '-ffreestanding', '-mgeneral-regs-only',
                 '-I', File.join(@root, 'include'), '-c', File.join(@root, 'kernel/core/watchdog.c'),
                 '-o', File.join(@directory, 'watchdog.o')], name: 'compile-target', deadline: 60)
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *@sanitizer_flags, '-I', File.join(@root, 'include'), core,
                 File.join(@root, 'test/fixtures/watchdog_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 60)
    output
  end

  def mutant_source(name, original, replacement, index:)
    source = File.read(File.join(@root, 'kernel/core/watchdog.c'))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place in the core"
    path = File.join(@directory, "mutant-#{index}.c")
    File.write(path, source.sub(original, replacement))
    path
  end

  # Breadth-first over (core state, model, last time); an event's time is
  # never before the previous event's, as the kernel clock never goes back.
  # An end is final, so nothing follows it.
  def explore(driver, mode:, config:)
    root = Node.new(state: UNARMED, spec: Spec.initial(mode: mode, config: config), now_ns: 0)
    seen = Set[root]
    frontier = [root]
    failures = []
    covered = Set.new
    edges = 0
    depth = 0
    until frontier.empty? || depth == DEPTH_MAX
      batch = frontier.flat_map do |node|
        KINDS.product(TIMES.select { |time| time >= node.now_ns }).map do |kind, time|
          Edge.new(node: node, kind: kind, now_ns: time)
        end
      end
      depth += 1
      edges += batch.size
      answers = step_all(driver, batch, mode: mode, config: config)
      frontier = batch.zip(answers).filter_map do |edge, answer|
        expectation, spec = edge.node.spec.on(edge.kind, edge.now_ns)
        # A broken core disagrees almost everywhere; the first few explain it.
        failures.concat(step_failures(edge, answer, expectation, spec)) if failures.size < FAILURES_KEPT
        covered << case_of(edge, answer)
        next if answer.action == :end || expectation.action == :end

        child = Node.new(state: answer.next_state, spec: spec, now_ns: edge.now_ns)
        child if seen.add?(child)
      end
    end
    Exploration.new(failures: failures, covered: covered, nodes: seen.size, edges: edges, depth: depth,
                    closed: frontier.empty?)
  end

  # Everything one step answered, against the model: the action, the end
  # fields (zero unless it ends) and the state the core would store.
  def step_failures(edge, answer, expectation, spec)
    label = "#{edge.kind} at #{edge.now_ns} from #{edge.node.state.to_h}"
    problems = []
    problems << "#{label}: action #{answer.action}, expected #{expectation.action}" if answer.action != expectation.action
    if expectation.action == :end
      fields = [answer.cause, answer.uptime_ns, answer.since_pet_ns]
      wanted = [CAUSE, edge.now_ns, expectation.since_pet_ns]
      problems << "#{label}: end fields #{fields}, expected #{wanted}" if fields != wanted
    elsif [answer.cause, answer.uptime_ns, answer.since_pet_ns] != [0, 0, 0]
      problems << "#{label}: end fields set without an end"
    end
    stored = answer.next_state.to_h.values
    problems << "#{label}: next state #{stored}, expected #{spec.core_state}" if stored != spec.core_state
    problems
  end

  # The case an edge exercised: the phase, the event, where its time falls
  # against an armed deadline, and the outcome.
  def case_of(edge, answer)
    state = edge.node.state
    where = if state.phase != :armed then :unarmed_or_off
            elsif state.deadline_ns == MAX then :saturated
            else (edge.now_ns <=> state.deadline_ns).then { { -1 => :before, 0 => :at, 1 => :after }.fetch(_1) }
            end
    [state.phase, edge.kind, where, answer.action]
  end

  def required_cases
    Set[[:unarmed, :pet, :unarmed_or_off, :none], [:unarmed, :tick, :unarmed_or_off, :reload],
        [:unarmed, :start, :unarmed_or_off, :arm], [:armed, :start, :before, :none],
        [:armed, :pet, :before, :none], [:armed, :pet, :at, :none], [:armed, :pet, :after, :none],
        [:armed, :tick, :before, :reload], [:armed, :tick, :at, :reload], [:armed, :tick, :after, :end],
        [:armed, :tick, :saturated, :reload], [:armed, :pet, :saturated, :none]]
  end

  def step_request(state, kind, now_ns, mode:, config:)
    format("step %d %d %d %s %s %d %d %s %d\n", config.period_s, config.deadline_s, config.boot_s, mode,
           state.phase, state.since_ns, state.deadline_ns, kind, now_ns)
  end

  def step_all(driver, edges, mode:, config:)
    requests = edges.map { |edge| step_request(edge.node.state, edge.kind, edge.now_ns, mode: mode, config: config) }
    run_driver(driver, requests).map { |line| decode_step(line) }
  end

  def step_one(state, kind, now_ns, mode: :normal, config: CONFIGS.first)
    decode_step(run_driver(@driver, [step_request(state, kind, now_ns, mode: mode, config: config)]).fetch(0))
  end

  def decode_step(line)
    fields = line.split
    raise Erx::Error, "malformed driver answer: #{line.inspect}" unless fields.size == 8 && fields[0] == 'step'

    phase, since, deadline, action, cause, uptime, since_pet = fields.drop(1)
    Answer.new(next_state: State.new(phase: phase.to_sym, since_ns: Integer(since, 10), deadline_ns: Integer(deadline, 10)),
               action: action.to_sym, cause: Integer(cause, 10), uptime_ns: Integer(uptime, 10),
               since_pet_ns: Integer(since_pet, 10))
  end

  def parse(value) = parse_all([value]).fetch(0)

  def parse_all(values)
    requests = values.map { |value| "parse #{value.empty? ? '-' : value.unpack1('H*')}\n" }
    run_driver(@driver, requests).map do |line|
      _, status, period, deadline, boot, reason = line.chomp.split(' ', 6)
      Parsed.new(status: status.to_sym, config: [period, deadline, boot].map { Integer(_1, 10) }, reason: reason.to_s)
    end
  end

  # Runs the events in order from the initial state, one answer per event.
  def trace(events, mode: :normal, config: CONFIGS.first)
    request = "trace #{config.period_s} #{config.deadline_s} #{config.boot_s} #{mode} " \
              "#{events.map { |kind, now_ns| "#{kind} #{now_ns}" }.join(' ')}\n"
    run_driver(@driver, [request], answers: events.size).map { |line| decode_step(line) }
  end

  def run_driver(driver, requests, answers: requests.size)
    input = File.join(@directory, 'requests.txt')
    File.write(input, requests.join)
    record = @runner.run([driver, input], name: 'watchdog-driver', deadline: 300)
    lines = File.readlines(record.fetch('log'))
    assert_equal answers, lines.size, 'one answer per request or event'
    lines
  end

  def expected_config(value)
    match = /\A(\d+),(\d+),(\d+)\z/.match(value) or return nil
    period, deadline, boot = match.captures.map { Integer(_1, 10) }
    return nil unless period.between?(PERIOD_MIN, PERIOD_MAX) &&
                      deadline.between?(DEADLINE_PERIODS_MIN * period, DEADLINE_MAX) && boot.between?(deadline, BOOT_MAX)

    [period, deadline, boot]
  end
end
