# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the deletion core and the release rule (kernel/core/delete.c), with
# the inserts (kernel/core/attach.c), through the exhaustive model of
# test/fixtures/delete_model.c over the real cores: every interleaving of
# each scenario's actors (deletions, closes, moves, copies, the emptying of
# a table, an operation that holds the existence lock and a reader of a
# borrowed pointer) keeps the model's checks, and each seeded mutant of the
# cores, a violation the design names, is caught.
class DeleteTest < Minitest::Test
  CORES = %w[kernel/core/object.c kernel/core/cap.c kernel/core/attach.c kernel/core/delete.c
             kernel/core/budget.c kernel/core/grace.c].freeze
  # Each scenario names its actors by the model's letters (see the model's
  # header comment): deletions racing operations and readers, releases
  # racing deletions, moves, copies and the emptying of a table, and the
  # destruction of X's budget racing deletions, releases, operations and
  # a publication under X's existence lock.
  SCENARIOS = %w[DOR DDOR DCM DEC DACO DEMA DCEM CEMR CEOR KD KC KO KP KDP KDC].freeze
  # The seeded publication, which links X on its parent without X's
  # existence lock (the model's actor U), and the diagnosis the design names.
  SEEDED_PUBLICATION = 'KU'
  SEEDED_PUBLICATION_CAUGHT = "a child attached to its parent after the parent's budget tore it down"
  # The release rule's actions, as erx/delete.h numbers them.
  RELEASE_DESTROY = 2
  RELEASE_LIVES_ON = 3
  LIVES_ON_TYPES = [4, 5].freeze # ERX_K_GROUP, ERX_K_MEMORY
  # Seeded violations: edits of the cores, each with the model's diagnosis.
  # Every edit must match its core exactly once.
  MUTANTS = {
    'an insert and a count without the state check' => {
      edits: [['kernel/core/attach.c', "\tif (erx_object_state(object) != ERX_OBJ_LIVE)\n\t\treturn (ERX_ESTALE);\n", ''],
              ['kernel/core/object.c', "if (erx_object_state(object) != ERX_OBJ_LIVE)\n\t\treturn (ERX_ESTALE);\n", '']],
      caught: 'an attachment after the close'
    },
    'a lookup without the state check' => {
      edits: [['kernel/core/cap.c', 'return (erx_object_state(object) == ERX_OBJ_LIVE &&', 'return (object != NULL &&']],
      caught: 'a lookup after the close'
    },
    'a teardown without the drain' => {
      edits: [['kernel/core/delete.c', "\t\tdestroy->stage = ERX_DELETE_CLOSED;\n\t\tpart.action = ERX_DELETE_DRAIN;\n\t\treturn (part);\n",
               "\t\tdestroy->stage = ERX_DELETE_TEARING;\n\t\treturn (delete_teardown_part(destroy->object));\n"]],
      caught: 'a teardown part while the existence lock is held'
    },
    'every close goes on' => {
      edits: [['kernel/core/delete.c', 'if (!erx_object_close(destroy->object)) {', 'if (!erx_object_close(destroy->object) && false) {']],
      caught: 'two destroys went on past the close'
    },
    'the put before the walk ends' => {
      edits: [['kernel/core/delete.c', "\tif (slot != NULL) {\n", "\tif (slot != NULL && false) {\n"]],
      caught: 'the teardown ended with a slot naming the object'
    },
    'the drain leaves its object on the list' => {
      edits: [['kernel/core/delete.c', "\t(void)erx_object_charged_unlink(erx_budget_charged(budget), object);\n", "\t(void)budget;\n"]],
      caught: "a closed object on its budget's list after its drain"
    },
    'a release of a closed object destroys it' => {
      edits: [['kernel/core/delete.c', "\tif (erx_object_state(object) == ERX_OBJ_DELETED)\n\t\treturn (ERX_RELEASE_NONE);\n", '']],
      caught: 'a release of a closed object destroys it'
    }
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-delete-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported delete-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_every_interleaving_of_every_scenario_keeps_the_checks
    model = build_model(CORES.map { |core| File.join(@root, core) }, name: 'model')
    SCENARIOS.each do |scenario|
      output = run_model(model, scenario)
      assert_match(/\Aexplored #{scenario}: \d+ steps, \d+ interleavings\n\z/, output, scenario)
      assert_operator Integer(output[/(\d+) interleavings/, 1]), :>=, 10, "#{scenario} explores too few interleavings"
    end
  end

  def test_the_model_catches_a_publication_without_the_existence_lock
    model = build_model(CORES.map { |core| File.join(@root, core) }, name: 'model')
    assert_equal SEEDED_PUBLICATION_CAUGHT, violation(model, SEEDED_PUBLICATION)
  end

  # Memory objects and groups live on after their release while attached;
  # every other type, and every unattached object, is destroyed.
  def test_the_release_rule_by_type
    model = build_model(CORES.map { |core| File.join(@root, core) }, name: 'rules')
    rules = run_model(model, 'rules').lines.map { |line| line.split.drop(1).map { |field| Integer(field) } }
    assert_equal (1..9).to_a, rules.map(&:first)
    rules.each do |type, attached, unattached|
      assert_equal LIVES_ON_TYPES.include?(type) ? RELEASE_LIVES_ON : RELEASE_DESTROY, attached, "type #{type}"
      assert_equal RELEASE_DESTROY, unattached, "type #{type}"
    end
  end

  MUTANTS.each do |name, mutant|
    define_method("test_the_model_catches_#{name.tr(' ', '_')}") do
      model = build_model(mutant_cores(name, mutant.fetch(:edits)), name: "mutant-#{name.tr(' ', '-')}")
      diagnoses = SCENARIOS.filter_map { |scenario| violation(model, scenario) }
      refute_empty diagnoses, "mutant #{name} survives every scenario"
      assert_includes diagnoses, mutant.fetch(:caught),
             "mutant #{name} caught only as: #{diagnoses.uniq.join('; ')}"
    end
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_model(cores, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-DERX_HOST',
                 *@sanitizer_flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/core'),
                 '-I', Erx::Generated.path('kernel/generated', root: @root), *cores,
                 File.join(@root, 'test/fixtures/delete_model.c'), '-o', output],
                name: "compile-#{name}", deadline: 180)
    output
  end

  def run_model(model, argument)
    record = @runner.run([model, argument], name: "model-#{argument.downcase}", deadline: 300)
    File.read(record.fetch('log'))
  end

  # The model's diagnosis of scenario, or nil when every check holds.
  def violation(model, scenario)
    run_model(model, scenario)
    nil
  rescue Erx::CommandError => e
    log = File.read(e.result.fetch('log'))
    log[/^violation: (.*)$/, 1] or flunk("the mutant model failed without a diagnosis: #{log.lines.first(5).join}")
  end

  # The cores with mutant's edits applied, each edited core copied beside
  # its private headers so its includes still resolve.
  def mutant_cores(name, edits)
    directory = File.join(@directory, "source-#{name.tr(' ', '-')}")
    FileUtils.mkdir_p(directory)
    edited = edits.group_by(&:first)
    CORES.map do |core|
      next File.join(@root, core) unless edited.key?(core)

      source = edited.fetch(core).reduce(File.read(File.join(@root, core))) do |text, (_, original, replacement)|
        assert_equal 1, text.scan(original).size, "mutant #{name} must edit exactly one place of #{core}"
        text.sub(original, replacement)
      end
      Dir.glob(File.join(@root, 'kernel/core/*_impl.h')).each { |header| FileUtils.cp(header, directory) }
      File.join(directory, File.basename(core)).tap { |path| File.write(path, source) }
    end
  end
end
