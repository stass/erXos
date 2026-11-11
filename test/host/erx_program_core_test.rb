# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The erx_program port's core (otp/erts/emulator/sys/erxos/erx_program_core.c) through its
# host driver, test/fixtures/erx_program_core_driver.c, under the address and undefined
# sanitizers. The model below is written from docs/design-runtime.md's "Programs as ports"
# and the order erx_gate.h and erx_event.h give a port. Every spec the driver names is
# checked against its expected answer; a start failing at each step k undoes exactly steps
# 1..k-1, last first, whether or not the undos themselves fail; every input in every state
# of the end reachable from a started program agrees with the model; and the guarantees
# erx_program_core.h states hold over every sequence of up to five inputs. Seeded failures
# of the core must each fail their check.
class ErxProgramCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'otp/erts/emulator/sys/erxos/erx_program_core.c'
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # The driver prints erx_program_act_t's and erx_program_phase_t's names, so no numbering is copied here.

  # The start's steps in order: the session's budget and group records, then the port's IRQ
  # object, sink, bind and both labels' gate registrations before any space carries a label,
  # then the spaces, the map and the thread.
  STEPS = %i[budget_create group_create irq_create sink_register irq_bind gate_register_anchor
             gate_register_image anchor_create image_create image_map thread_create thread_start].freeze
  # What undoes each step that made something; a map dies with its space, and the start is last.
  UNDO = { budget_create: :budget_destroy, group_create: :group_close, irq_create: :irq_close,
           sink_register: :sink_unregister, irq_bind: :irq_unbind,
           gate_register_anchor: :gate_unregister_anchor, gate_register_image: :gate_unregister_image,
           anchor_create: :anchor_destroy, image_create: :image_close, thread_create: :thread_close }.freeze
  RELEASE = STEPS.reverse.filter_map { UNDO[_1] }.freeze

  # Each spec the driver names and the status constant erx_program_spec_check answers.
  SPECS = {
    'good' => :ok, 'one-byte' => :ok, 'empty' => :einval, 'absolute' => :einval,
    'trailing-slash' => :einval, 'empty-component' => :einval, 'dot' => :einval, 'dot-dot' => :einval,
    'dot-alone' => :einval, 'dot-dot-alone' => :einval, 'dot-prefix' => :ok, 'dots-name' => :ok,
    'control' => :einval, 'delete' => :einval, 'nul' => :einval, 'high-byte' => :ok, 'longest' => :ok,
    'too-long' => :einval, 'pid-0' => :erange, 'pid-1' => :erange, 'pid-negative' => :erange,
    'pid-max' => :ok, 'pid-past-max' => :erange, 'pid-int64-min' => :erange,
    'guarantee-equals-cap' => :ok, 'guarantee-above-cap' => :einval, 'cap-equals-pool' => :ok,
    'cap-above-pool' => :elimit, 'cap-max' => :elimit
  }.freeze

  # The end's state as the driver prints it: the phase, FAULTED's status, and three flags.
  State = Data.define(:phase, :status, :anchor_ended, :answered, :close_held)
  STARTED = State.new(phase: :running, status: 0, anchor_ended: false, answered: false, close_held: false)

  # The model of the end, given the driver's constants (k) and the fault table (signals).
  class EndModel
    def initialize(constants, signals)
      @k = constants
      @signals = signals
    end

    def call(state, input)
      return [state.with(answered: true, close_held: false), state.close_held ? [[:close_port, 0]] : []] if input == [:answered]
      return [input == [:close] ? state.with(close_held: false) : state, []] if state.phase == :released

      case [state.phase, *input]
      in [:ended, :image_exit, _] then [state, []]
      # The fault's status only for an image its anchor's stop ended; an earlier halt is its own.
      in [:faulted, :image_exit, n] then image_ended(state, [[:report, n == @k.fetch('exit_parent') ? state.status : n]])
      in [:running, :image_exit, n] then image_ended(state, [[:report, n]] + stop(state, anchor_status(n)))
      in [:ended, :anchor_exit, _] then release(state, port_open: true)
      in [_, :anchor_exit, _] then [state.with(anchor_ended: true), []]
      in [:running, :fault, kind] then [state.with(phase: :faulted, status: fault_status(kind)), stop(state, fault_status(kind))]
      in [_, :fault, _] then [state, []]
      in [phase, :close | :lost => how]
        release(state, before: phase == :running ? stop(state, @k.fetch('killed')) : [], port_open: how == :lost)
      end
    end

    private

    # A stop of the anchor, unless its exit record arrived.
    def stop(state, status) = state.anchor_ended ? [] : [[:stop_anchor, status]]

    def image_ended(state, actions)
      ended = state.with(phase: :ended, status: 0)
      state.anchor_ended ? release(ended, before: actions, port_open: true) : [ended, actions]
    end

    # The port's close comes with the release once the answer was read, else it is held.
    def release(state, port_open:, before: [])
      close = port_open && state.answered ? [[:close_port, 0]] : []
      [STARTED.with(phase: :released, answered: state.answered, close_held: port_open && !state.answered),
       before + RELEASE.map { [_1, 0] } + close]
    end

    # erx_space_stop refuses the kernel's own statuses, so an image that ended by one has its
    # anchor stopped as a close would.
    def anchor_status(n)
      kernel_own = %w[exit_parent exit_released exit_nothread].map { @k.fetch(_1) }
      kernel_own.include?(n) ? @k.fetch('killed') : n
    end

    def fault_status(kind)
      signal = @signals.fetch(kind)
      @k.fetch('exit_signal') + (signal.zero? ? @k.fetch('sigkill') : signal)
    end
  end

  def test_specs_are_checked
    assert_equal SPECS.keys.sort, output[:specs].keys.sort
    wrong = SPECS.reject { |name, status| output[:specs][name] == constant(status.to_s) }
    assert_empty wrong.keys, "specs answered wrongly: #{wrong.keys.map { [_1, output[:specs][_1]] }}"
  end

  def test_a_failed_step_undoes_exactly_the_steps_before_it
    assert_empty start_differences(output), start_differences(output).join("\n")
  end

  def test_every_end_transition_agrees_with_the_model
    assert_empty end_differences(output), end_differences(output).first(20).join("\n")
  end

  def test_the_guarantees_hold_over_input_sequences
    assert_empty broken_guarantees(output), broken_guarantees(output).first(20).join("\n")
  end

  # A seeded failure of the core, the check that must catch it, and the edit that plants it.
  MUTANTS = {
    'an undo is skipped' =>
      [:start_differences, '{ ERX_PROGRAM_GATE_REGISTER_IMAGE, ERX_PROGRAM_GATE_UNREGISTER_IMAGE },',
       '{ ERX_PROGRAM_GATE_REGISTER_IMAGE, NO_UNDO },'],
    'two steps are swapped' =>
      [:start_differences,
       "{ ERX_PROGRAM_GATE_REGISTER_IMAGE, ERX_PROGRAM_GATE_UNREGISTER_IMAGE },\n\t{ ERX_PROGRAM_ANCHOR_CREATE, ERX_PROGRAM_ANCHOR_DESTROY },",
       "{ ERX_PROGRAM_ANCHOR_CREATE, ERX_PROGRAM_ANCHOR_DESTROY },\n\t{ ERX_PROGRAM_GATE_REGISTER_IMAGE, ERX_PROGRAM_GATE_UNREGISTER_IMAGE },"],
    "a fault's status is lost to the image's exit record" =>
      [:broken_guarantees, '? end->status : input.status', '? input.status : input.status'],
    "a fault's status overrides the image's own halt" =>
      [:broken_guarantees, 'input.status == ERX_EXIT_PARENT ? end->status : input.status', 'end->status'],
    'a released program still acts' =>
      [:end_differences, 'if (end->phase == ERX_PROGRAM_RELEASED) {', 'if (0) {'],
    'the port closes before the start answer is read' =>
      [:broken_guarantees, 'if (!closing && end->answered)', 'if (!closing)'],
    "the image's and the anchor's exits are swapped" =>
      [:end_differences, 'space == ERX_PROGRAM_SPACE_ANCHOR ?', 'space == ERX_PROGRAM_SPACE_IMAGE ?'],
    "the anchor's exit releases before the image's report" =>
      [:broken_guarantees, 'end->phase == ERX_PROGRAM_ENDED ? release(end, actions, 0, false) : 0',
       'release(end, actions, 0, false)']
  }.freeze

  def test_seeded_failures_are_caught
    source = File.read(File.join(ROOT, CORE))
    Dir.mktmpdir('erx-program-core-mutant-') do |directory|
      MUTANTS.each do |name, (check, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
        path = File.join(directory, "#{name.tr(" '", '--')}.c")
        File.write(path, source.sub(original, replacement))
        refute_empty send(check, parse(run_driver(build(path)))), "seeded failure not caught: #{name}"
      end
    end
  end

  private

  def output = @output ||= parse(run_driver(build(File.join(ROOT, CORE))))

  def constant(name) = output[:constants].fetch(name)

  def start_differences(out)
    k = out[:constants]
    expected = { 'ok' => [STEPS, k.fetch('ok')], 'refused' => [[], k.fetch('erange')],
                 'first-call-fails' => [[], k.fetch('step_failure')], 'after-done' => [STEPS, k.fetch('ok')] }
    (1..STEPS.size).each do |step|
      run = [STEPS.first(step) + STEPS.first(step - 1).reverse.filter_map { UNDO[_1] }, k.fetch('step_failure')]
      expected["fail-#{step}"] = run
      expected["undo-fail-#{step}"] = run
    end
    differences = expected.reject { |name, run| out[:starts][name] == run }
    differences.map { |name, run| "start #{name}: got #{out[:starts][name].inspect}, want #{run.inspect}" } +
      (out[:starts].keys - expected.keys).map { "start #{_1}: not expected" }
  end

  def end_differences(out)
    model = EndModel.new(out[:constants], out[:signals])
    out[:ends].filter_map do |(state, input), got|
      want = model.call(state, input)
      "end #{state.to_h} #{input.inspect}: got #{got.inspect}, want #{want.inspect}" unless got == want
    end
  end

  # Walks every sequence of up to five inputs from a started program through the driver's own
  # table and checks erx_program_core.h's guarantees on what each sequence asked for.
  def broken_guarantees(out)
    k = out[:constants]
    inputs = [[:image_exit, 0], [:image_exit, 42], [:image_exit, k.fetch('exit_parent')],
              [:anchor_exit, k.fetch('killed')], [:fault, 1], [:fault, 10], [:close], [:lost], [:answered]]
    (1..5).flat_map { inputs.repeated_permutation(_1).to_a }.filter_map do |sequence|
      problem = sequence_problem(out, sequence)
      "#{sequence.inspect}: #{problem}" if problem
    end
  end

  def sequence_problem(out, sequence)
    state = STARTED
    asked = sequence.map do |input|
      row = out[:ends][[state, input]] or return "no row for #{state.to_h} #{input.inspect}"
      state = row.first
      row.last
    end
    release_violation(sequence, asked, state) || port_violation(sequence, asked) ||
      report_violation(out, sequence, asked)
  end

  # The anchor's stop and the release: each at most once, the release whole, and nothing of
  # the program after it.
  def release_violation(sequence, asked, state)
    acts = asked.flatten(1).map(&:first)
    released_at = asked.index { |actions| actions.map(&:first).include?(:budget_destroy) }
    anchor_ended_at = sequence.index { _1.first == :anchor_exit }
    return 'more than one anchor stop' if acts.count(:stop_anchor) > 1
    return "an anchor stopped after its exit" if anchor_ended_at && asked.drop(anchor_ended_at).flatten(1).any? { _1.first == :stop_anchor }
    return 'released but no release' if state.phase == :released && released_at.nil?
    return nil unless released_at
    return 'a release is not whole or not once' if acts.each_cons(RELEASE.size).count(RELEASE) != 1

    after = asked[released_at].map(&:first).drop_while { _1 != RELEASE.last }.drop(1) +
            asked.drop(released_at + 1).flatten(1).map(&:first)
    'actions of the program after the release' unless after.all?(:close_port)
  end

  # The port's close: at most once, never at or after a close of the port, never before the
  # start's answer is read, and owed once the program released with the answer read.
  def port_violation(sequence, asked)
    closes = asked.each_index.select { |at| asked[at].any? { _1.first == :close_port } }
    answered_at = sequence.index([:answered])
    closed_at = sequence.index([:close])
    released_at = asked.index { |actions| actions.map(&:first).include?(:budget_destroy) }
    return 'more than one close of the port' if asked.flatten(1).count { _1.first == :close_port } > 1
    return 'the port closed before the answer was read' if closes.any? { answered_at.nil? || _1 < answered_at }
    return 'the port closed after it was closing' if closes.any? { closed_at && _1 >= closed_at }
    owed = released_at && sequence[released_at] != [:close] && answered_at && closed_at.nil?
    'the port was never closed' if owed && closes.empty?
  end

  # The one report: from the image's exit record before any close or loss, with its status,
  # or the first fault's status for an image the fault's stop ended.
  def report_violation(out, sequence, asked)
    reports = asked.flatten(1).select { _1.first == :report }
    live = sequence.take_while { !%i[close lost].include?(_1.first) }
    image_at = live.index { _1.first == :image_exit }
    want = []
    if image_at
      fault = live.first(image_at).find { _1.first == :fault }
      status = live[image_at].last
      by_stop = fault && status == out[:constants].fetch('exit_parent')
      want = [[:report, by_stop ? fault_status(out, fault.last) : status]]
    end
    "reported #{reports.inspect}, want #{want.inspect}" unless reports == want
  end

  def fault_status(out, kind)
    k = out[:constants]
    signal = out[:signals].fetch(kind)
    k.fetch('exit_signal') + (signal.zero? ? k.fetch('sigkill') : signal)
  end

  def build(source)
    @directory ||= Dir.mktmpdir('erx-program-core-')
    binary = File.join(@directory, File.basename(source, '.c'))
    log, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT),
                                  '-I', File.join(ROOT, 'include'),
                                  '-I', File.join(ROOT, 'otp/erts/emulator/sys/erxos'),
                                  File.join(ROOT, 'test/fixtures/erx_program_core_driver.c'), source,
                                  '-o', binary, stdin_data: '')
    assert status.success?, log
    binary
  end

  # The driver's lines. Anything but a clean exit, a sanitizer's report included, is a broken run.
  def run_driver(binary)
    log, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    assert status.success?, log
    log.lines(chomp: true)
  end

  def parse(lines)
    out = { acts: {}, phases: {}, constants: {}, signals: {}, specs: {}, starts: {}, ends: {} }
    lines.each { parse_line(out, _1.split) }
    out
  end

  def parse_line(out, words)
    case words
    in ['const', name, value] then out[:constants][name] = Integer(value)
    in ['signal', kind, signal] then out[:signals][Integer(kind)] = Integer(signal)
    in ['spec', name, status] then out[:specs][name] = Integer(status)
    in ['act', value, name] then out[:acts][Integer(value)] = name.to_sym
    in ['phase', value, name] then out[:phases][Integer(value)] = name.to_sym
    in ['start', name, *acts, '=', error] then out[:starts][name] = [acts.map { out[:acts].fetch(Integer(_1)) }, Integer(error)]
    in ['end', *row] then parse_end(out, *row.slice_when { |word, _| word == '=' }.map { _1 - ['='] })
    end
  end

  def parse_end(out, before, after)
    out[:ends][[state_of(out, before.first(5)), input_of(before.drop(5))]] =
      [state_of(out, after.first(5)), after.drop(5).map { action_of(out, _1) }]
  end

  def state_of(out, (phase, status, anchor_ended, answered, close_held))
    State.new(phase: out[:phases].fetch(Integer(phase)), status: Integer(status),
              anchor_ended: anchor_ended == '1', answered: answered == '1', close_held: close_held == '1')
  end

  def input_of(words) = [words.first.to_sym, *words.drop(1).map { Integer(_1) }]

  def action_of(out, word)
    act, status = word.split(':')
    [out[:acts].fetch(Integer(act)), Integer(status)]
  end

  def teardown
    FileUtils.rm_rf(@directory) if @directory
  end
end
