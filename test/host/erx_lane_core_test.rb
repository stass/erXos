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

# The lane port's decisions (otp/erts/emulator/sys/erxos/erx_lane_core.c) through their host
# driver, test/fixtures/erx_lane_core_driver.c, which prints erx_lane_port_decide's answer for
# every state, event and combination of the facts it reads, under the address and undefined
# sanitizers. Every answer is compared with the model below, written from
# docs/design-runtime.md's finish; the guarantees erx_lane_core.h states are checked over the
# whole table; and the finish's cases are walked as the driver applies them, each frame and
# empty take behind a RUN that took: a record the stop cuts short, a full answers bound, a
# second finish, a malformed frame during the finish, and a finish with no entry yet. Seeded failures of the core must each fail its case.
class ErxLaneCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'otp/erts/emulator/sys/erxos/erx_lane_core.c'
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # The enums' numbering in erx_lane_core.h and erx/funnel.h.
  STATES = %i[running finishing finished].freeze
  EVENTS = %i[finish output kept run frame empty].freeze
  ACTIONS = %i[malformed deliver deliver_if_linked drop answer_noproc answer_spawn too_large].freeze
  DOS = %i[nothing refuse stop write resume take act end_malformed end_answers tell].freeze
  # LINK, MONITOR_P, SPAWN_REQUEST and UNLINK_ID, by OTP's operation numbers.
  ANSWERED_OPS = [1, 19, 29, 35].freeze
  ANSWER_ONLY = %i[answer_noproc answer_spawn deliver_if_linked].freeze
  # What each event may make the driver do.
  VOCABULARY = { finish: %i[refuse stop], output: %i[nothing write], kept: %i[nothing resume],
                 run: %i[nothing take], frame: %i[nothing act end_malformed end_answers],
                 empty: %i[nothing tell] }.freeze

  Fact = Data.define(:state, :event, :entry, :action, :op, :full, :cut)
  Decision = Data.define(:state, :what, :drop)

  # The design's finish, as a model of its own.
  module Model
    module_function

    def decide(fact)
      case [fact.event, fact.state]
      in [:finish, :running] then Decision.new(:finishing, :stop, false)
      in [:finish, state] then Decision.new(state, :refuse, false)
      in [:output, :running] then Decision.new(:running, :write, false)
      in [:output, state] then Decision.new(state, :nothing, true)
      in [:kept, :running] then Decision.new(:running, :resume, false)
      in [:kept, state] then Decision.new(state, :nothing, false)
      in [:run, :finishing] then Decision.new(:finishing, :take, false)
      in [:run, :running] then Decision.new(:running, fact.entry ? :take : :nothing, false)
      in [:run, :finished] then Decision.new(:finished, :nothing, false)
      in [:frame, state] then Decision.new(state, *frame(fact))
      in [:empty, :finishing] then Decision.new(:finished, :tell, fact.cut)
      in [:empty, state] then Decision.new(state, :nothing, false)
      end
    end

    # A frame's action and whether it is dropped: nothing past the finish, a malformed frame
    # ends the port, nothing is acted on without an entry or answered while finishing, and the
    # answers bound ends only a running port.
    def frame(fact)
      return [:nothing, true] if fact.state == :finished
      return [:end_malformed, false] if fact.action == :malformed
      return [:nothing, true] if !fact.entry || (fact.state == :finishing && ANSWER_ONLY.include?(fact.action))
      return [:end_answers, false] if fact.state == :running && fact.full && fact.action != :drop &&
                                      ANSWERED_OPS.include?(fact.op)

      [:act, false]
    end
  end

  # One of the finish's cases, walked through a table as the driver applies its decisions.
  Walk = Data.define(:state, :whats, :dropped, :told)

  def test_every_decision_agrees_with_the_model
    table, answered = run_driver(build(File.join(ROOT, CORE)))
    assert_equal STATES.size * EVENTS.size * 2 * ACTIONS.size * 14 * 2 * 2, table.size
    assert_equal [], model_differences(table)
    assert_equal ANSWERED_OPS, answered.select { |_, yes| yes }.keys.sort
  end

  def test_the_guarantees_hold_over_the_whole_table
    table, = run_driver(build(File.join(ROOT, CORE)))
    assert_equal [], broken_guarantees(table)
  end

  def test_the_finish_cases
    table, = run_driver(build(File.join(ROOT, CORE)))
    assert_equal [], failed_cases(table)
  end

  # A seeded failure of the core, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'a finish takes the cut record as malformed' =>
      ['cut record',
       'return (decided(ERX_LANE_PORT_FINISHED, ERX_LANE_DO_TELL, cut));',
       'return (decided(ERX_LANE_PORT_FINISHED, cut ? ERX_LANE_DO_END_MALFORMED : ERX_LANE_DO_TELL, false));'],
    'a finish keeps the answers bound' =>
      ['answers bound', 'if (state == ERX_LANE_PORT_RUNNING && input->answers_full', 'if (input->answers_full'],
    'a finish queues answers it never sends' =>
      ['answers bound', '(state == ERX_LANE_PORT_FINISHING && answer_only(input->action))',
       '(state == ERX_LANE_PORT_FINISHED && answer_only(input->action))']
  }.freeze

  def test_seeded_failures_are_caught
    source = File.read(File.join(ROOT, CORE))
    Dir.mktmpdir('erx-lane-core-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
        path = File.join(directory, "#{name.tr(' ', '-')}.c")
        File.write(path, source.sub(original, replacement))
        table, = run_driver(build(path))
        assert_includes failed_cases(table), expected, "seeded failure not caught by its case: #{name}"
        refute_empty model_differences(table), "seeded failure not caught by the model: #{name}"
      end
    end
  end

  private

  def model_differences(table)
    table.reject { |fact, decision| Model.decide(fact) == decision }.keys.first(5)
  end

  # erx_lane_core.h's guarantees, each over every row.
  def broken_guarantees(table)
    checks = {
      'an event does only what it may' => ->(f, d) { VOCABULARY.fetch(f.event).include?(d.what) },
      'only a running port writes or resumes' => ->(f, d) { !%i[write resume].include?(d.what) || f.state == :running },
      'a finished port takes, acts and tells nothing' =>
        ->(f, d) { f.state != :finished || !%i[take act tell end_malformed end_answers].include?(d.what) },
      'a frame is acted on only through an entry' => ->(f, d) { d.what != :act || f.entry },
      'a finishing port acts on no answer-only frame' =>
        ->(f, d) { !(f.state == :finishing && d.what == :act && ANSWER_ONLY.include?(f.action)) },
      'a finishing port always takes, so its finish ends' =>
        ->(f, d) { !(f.state == :finishing && f.event == :run) || d.what == :take },
      'the answers bound ends only a running port' => ->(f, d) { d.what != :end_answers || f.state == :running },
      'the agent is told once, at the finish, with the cut record counted' =>
        ->(f, d) { (d.what == :tell) == (f.state == :finishing && f.event == :empty) && (d.what != :tell || d.drop == f.cut) },
      'the state only moves forward, and only at the finish and its end' =>
        ->(f, d) { d.state == f.state || ([f.state, f.event, d.state] in [:running, :finish, :finishing] | [:finishing, :empty, :finished]) }
    }
    checks.filter_map do |name, holds|
      bad = table.find { |fact, decision| !holds.call(fact, decision) }
      "#{name}: #{bad.first.to_h} -> #{bad.last.to_h}" if bad
    end
  end

  # The finish's cases, each walked from a state through its steps; the names of those that fail.
  def failed_cases(table)
    cases = {
      'cut record' => lambda {
        walk = walk(table, :running, [step(:finish), step(:run), step(:frame), step(:empty, cut: true), step(:run)])
        walk.state == :finished && walk.told == 1 && walk.dropped == 1 && walk.whats == %i[stop take act tell nothing]
      },
      'answers bound' => lambda {
        running = walk(table, :running, [step(:run), step(:frame, op: 1, full: true)])
        finishing = walk(table, :finishing, [step(:run), step(:frame, op: 1, full: true),
                                             step(:frame, action: :answer_noproc, op: 19, full: true),
                                             step(:frame, action: :answer_spawn, op: 29, full: true),
                                             step(:frame, action: :deliver_if_linked, op: 1, full: true),
                                             step(:empty)])
        running.whats == %i[take end_answers] && finishing.whats == %i[take act nothing nothing nothing tell] &&
          finishing.dropped == 3 && finishing.told == 1
      },
      'second finish' => lambda {
        walk = walk(table, :running, [step(:finish), step(:finish), step(:run), step(:empty), step(:finish)])
        walk.whats == %i[stop refuse take tell refuse] && walk.state == :finished && walk.told == 1
      },
      'malformed during the finish' => lambda {
        walk = walk(table, :finishing, [step(:run), step(:frame), step(:frame, action: :malformed)])
        walk.whats == %i[take act end_malformed] && walk.told.zero? && walk.state == :finishing
      },
      'no entry yet' => lambda {
        walk = walk(table, :running, [step(:run), step(:finish), step(:run), step(:frame), step(:frame),
                                      step(:empty, cut: true)], entry: false)
        walk.whats == %i[nothing stop take nothing nothing tell] && walk.dropped == 3 && walk.told == 1
      },
      'output during the finish' => lambda {
        walk = walk(table, :running, [step(:output), step(:kept), step(:finish), step(:output), step(:kept)])
        walk.whats == %i[write resume stop nothing nothing] && walk.dropped == 1
      }
    }
    cases.reject { |_, holds| holds.call }.keys
  end

  # An event and its facts; a frame is a SEND_SENDER delivered unless said otherwise.
  def step(event, action: :deliver, op: 22, full: false, cut: false) = { event:, action:, op:, full:, cut: }

  # Applies each step's decision as port_decide does: the next state, the drop count, the tell.
  # Every walk takes frames and empty takes only after a RUN that took, as the driver does.
  def walk(table, state, steps, entry: true)
    steps.reduce(Walk.new(state: state, whats: [], dropped: 0, told: 0)) do |walked, facts|
      decision = table.fetch(Fact.new(state: walked.state, entry: entry, **facts))
      walked.with(state: decision.state, whats: [*walked.whats, decision.what],
                  dropped: walked.dropped + (decision.drop ? 1 : 0), told: walked.told + (decision.what == :tell ? 1 : 0))
    end
  end

  def build(source)
    @directory ||= Dir.mktmpdir('erx-lane-core-')
    binary = File.join(@directory, File.basename(source, '.c'))
    output, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT),
                                     '-I', File.join(ROOT, 'include'),
                                     '-I', File.join(ROOT, 'otp/erts/emulator/sys/erxos'),
                                     File.join(ROOT, 'test/fixtures/erx_lane_core_driver.c'), source,
                                     '-o', binary, stdin_data: '')
    assert status.success?, output
    binary
  end

  # The table, from each fact to its decision, and erx_lane_port_answered by operation.
  def run_driver(binary)
    output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    assert status.success?, output
    rows, answered = output.lines.map(&:split).partition { |words| words.first != 'answered' }
    [rows.to_h { |words| decode(words) }, answered.to_h { |_, op, yes| [Integer(op), yes == '1'] }]
  end

  def decode(words)
    state, event, entry, action, op, full, cut, _arrow, next_state, what, drop = words
    [Fact.new(state: STATES.fetch(Integer(state)), event: EVENTS.fetch(Integer(event)), entry: entry == '1',
              action: ACTIONS.fetch(Integer(action)), op: Integer(op), full: full == '1', cut: cut == '1'),
     Decision.new(state: STATES.fetch(Integer(next_state)), what: DOS.fetch(Integer(what)), drop: drop == '1')]
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && passed? && File.directory?(@directory)
  end
end
