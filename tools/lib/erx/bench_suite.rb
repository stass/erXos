# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'declaration_files'
require_relative 'error'
require_relative 'line_escape'
require_relative 'native_bench'
require_relative 'xdomain_bench'

module Erx
  # The benchmarks' declarations and the landing `bench` QEMU suite built from them
  # (docs/design-bench.md, "A benchmark", "The gates"). Each benchmark is one file in
  # benches/, named after it and found by globbing, as a QEMU suite is; the file calls
  # declare_benchmark once with its operations and its landing cells per boot. The
  # suite's cells are each boot's benchmarks, and each takes the worst of its benchmark
  # cells' statuses through SUITE_STATUS.
  module BenchSuite
    # The systems an operation's counterpart can name, and the plain words of its line.
    OTHER_SYSTEMS = (BenchRecord::SYSTEMS - ['erxos']).freeze
    COUNTERPART = /\A[A-Za-z0-9_][ -~]{0,159}\z/

    # An operation: an exact act with a start and an end on one clock, the profile it is
    # sampled by, and what a correct result of the act is. A handshake (one thread acts,
    # another answers before the first acts again) cannot be batched, so it is exempt
    # from the short operations' batches and reports batch 1 (docs/design-bench.md, "The
    # one clock"). A periodic operation whose timer rounds its own deadlines is declared
    # sweep: false, and its lines carry no sweep phases (docs/design-bench.md, "A benchmark").
    # counterparts maps each other system that runs a counterpart of the operation to
    # what it runs, the line the side-by-side table prints; a system it does not name is
    # not asked for the operation (docs/design-bench.md, "Counterparts").
    Operation = Data.define(:name, :profile, :result, :handshake, :sweep, :counterparts) do
      def initialize(name:, profile:, result:, handshake: false, sweep: true, counterparts: {})
        BenchRecord.check(name.is_a?(String) && BenchRecord::NAME.match?(name), 'operation is not a plain name')
        BenchRecord.check(BenchRecord::PROFILES.include?(profile), 'profile is not one of the profiles')
        BenchRecord.check(result.is_a?(String) && !result.empty?, "#{name} does not say what a correct result is")
        BenchRecord.check([true, false].include?(handshake), "#{name}'s handshake is neither true nor false")
        BenchRecord.check([true, false].include?(sweep), "#{name}'s sweep is neither true nor false")
        BenchRecord.check(sweep || profile == 'periodic', "#{name} is not periodic, so it has no sweep to decline")
        BenchRecord.check(counterparts.is_a?(Hash) &&
                          counterparts.all? { |system, line| OTHER_SYSTEMS.include?(system) && COUNTERPART.match?(line) },
                          "#{name}'s counterparts are not other systems' lines in plain words")
        super(name: name, profile: profile, result: result, handshake: handshake, sweep: sweep,
              counterparts: counterparts.freeze)
      end
    end

    # A placement names where a cell's work runs; its value is the CPUs an environment
    # needs for it. A cell on two CPUs is expected unsupported where there is one.
    PLACEMENTS = {
      'same-cpu' => 1, 'cross-cpu' => 2, 'service-cpu' => 1, 'other-cpu' => 2, 'runtime' => 1
    }.freeze

    # One cell of the landing matrix: an operation under a load cell, a placement and
    # the workload parameters that differ from the operation's defaults.
    LandingCell = Data.define(:operation, :load, :placement, :parameters) do
      def initialize(operation:, load:, placement:, parameters:)
        BenchRecord.check(PLACEMENTS.key?(placement), 'placement is not one of the placements')
        BenchRecord.check(load.is_a?(String) && BenchRecord::NAME.match?(load), 'load cell is not a plain name')
        BenchRecord.check(BenchRecord.plain_hash?(parameters), 'workload parameters are not a map')
        super(operation: operation, load: load, placement: placement, parameters: parameters.freeze)
      end

      # The CPUs the cell's placement spans.
      def cpus = PLACEMENTS.fetch(placement)
    end

    # A landing boot: the environment kind and CPU count it boots at, and the layer its
    # cells measure, which names its side-by-side table (docs/design-bench.md,
    # "Counterparts"): the native boot's C cells set the kernels' own paths beside each
    # other, the xdomain boot's Erlang cells the runtimes' messages.
    Boot = Data.define(:kind, :cpus, :layer)
    BOOTS = {
      'native' => Boot.new(kind: 'qemu-hvf', cpus: 4, layer: 'C'),
      'xdomain' => Boot.new(kind: 'qemu-hvf', cpus: 4, layer: 'Erlang')
    }.freeze

    # A benchmark: its operations by name and its landing cells per boot, each naming a
    # declared operation.
    Benchmark = Data.define(:name, :operations, :landing) do
      def initialize(name:, operations:, landing:)
        BenchRecord.check(BenchRecord::NAME.match?(name), "benchmark #{name.dump} is not a plain name")
        BenchRecord.check(landing.keys.all? { |boot| BOOTS.key?(boot) }, "#{name} names a boot the suite lacks")
        unknown = landing.values.flatten.map(&:operation).uniq - operations.keys
        BenchRecord.check(unknown.empty?, "#{name}'s landing matrix names an operation it does not declare")
        super(name: name, operations: operations.freeze, landing: landing.transform_values(&:freeze).freeze)
      end
    end

    # A benchmark cell's status to its suite cell (docs/design-bench.md, "Cells and suite
    # cells"); an unsupported cell the environment is expected to lack passes instead.
    SUITE_STATUS = {
      'measured' => 'passed', 'unsupported' => 'partial', 'partial' => 'partial', 'rejected' => 'partial',
      'timed_out' => 'timed_out', 'not_run' => 'not_run', 'failed' => 'failed'
    }.freeze
    # Suite cell statuses from worst to best.
    WORST_FIRST = %w[failed timed_out not_run partial passed].freeze

    BENCHMARK_FILES = DeclarationFiles.new('benchmarks')

    module_function

    # Each file under benches/ calls this exactly once.
    def declare_benchmark(operations:, landing:)
      BENCHMARK_FILES.declare([operations, landing])
    end

    def benchmarks
      @benchmarks ||= BENCHMARK_FILES.load_all(File.join(__dir__, 'benches')).to_h do |name, (operations, landing)|
        [name, Benchmark.new(name: name, operations: operations.to_h { |operation| [operation.name, operation] },
                             landing: landing)]
      end.freeze
    end

    def benchmark(name) = benchmarks.fetch(name) { raise Error, "unknown benchmark #{name}" }

    # The suite's cells: each boot's benchmarks, named as a QEMU cell that carries its
    # case (Erx::QemuCells::CELL_CASE_NAME): "hvf-4cpu-native-wake".
    def suite_cells = BOOTS.keys.flat_map { |boot| booted(boot).map { |declared| suite_cell_name(boot, declared.name) } }

    def suite_cell_name(boot, benchmark)
      entry = BOOTS.fetch(boot)
      "#{entry.kind.delete_prefix('qemu-')}-#{entry.cpus}cpu-#{boot}-#{benchmark}"
    end

    # The suite cell of one benchmark in one boot, from its cells' [status,
    # expected_unsupported] pairs: the worst of their suite statuses, not_run for none.
    def suite_cell(cells)
      return 'not_run' if cells.empty?

      cells.map { |status, expected| status == 'unsupported' && expected ? 'passed' : SUITE_STATUS.fetch(status) }
           .min_by { |status| WORST_FIRST.index(status) }
    end

    # Whether environment lacks the CPUs a placement needs (a LandingCell's, or a
    # recorded cell's conditions), so unsupported is the answer the declaration expects
    # there. Deterministic mode runs one CPU.
    def expected_unsupported?(placed, environment)
      cpus = environment.kind == 'qemu-det' ? 1 : environment.cpus
      !cpus.nil? && cpus < PLACEMENTS.fetch(placed.placement)
    end

    # The suite cell of one boot's benchmark from its record: the worst of that
    # benchmark's cells, each judged in the record's environment, at best partial when a
    # line of the boot was refused, since what it said is unknown, and failed when the
    # boot's seeded run did not show its fault. A boot with no seeded run passes nothing
    # for seed_caught.
    def boot_cell(record, benchmark:, refused:, seed_caught: true)
      return 'failed' unless seed_caught

      judged = record.boot.cells.select { |cell| cell.benchmark == benchmark }
                     .map { |cell| [cell.status, expected_unsupported?(cell.conditions, record.environment)] }
      suite_cell(judged + (refused.empty? ? [] : [['rejected', false]]))
    end

    # One landing of the suite's run: the boot, the label its notes carry, the benchmarks
    # whose cells its record holds, and its outcome (Landing#call's answer, or { error: }).
    Landed = Data.define(:boot, :label, :benchmarks, :outcome)

    # The suite's run, one landing after another, each recorded in history: every
    # benchmark's native boot and its seeded runs (native, a NativeBench::Landing), then
    # the xdomain boot's cells of every benchmark it runs (xdomain, an
    # XdomainBench::Landing). Each landing is given, for a test, or made for context's
    # tree. A landing that fails is a failed cell for each of its benchmarks, so the
    # others' cells stand; an xdomain boot that ends at a QEMU deadline is recorded with
    # its unreported cells timed_out, while a native boot at its deadline raises, so its
    # benchmark's cell is failed with no record.
    def run(context, history: BenchRecord.history, native: NativeBench::Landing.new(root: context.root),
            xdomain: XdomainBench::Landing.new(root: context.root))
      landed = booted('native').map do |declared|
        Landed.new(boot: 'native', label: "native: #{declared.name}", benchmarks: [declared],
                   outcome: outcome(native, declared, boot: 'native', history: history))
      end
      landed << Landed.new(boot: 'xdomain', label: 'xdomain', benchmarks: booted('xdomain'),
                           outcome: outcome(xdomain, booted('xdomain'), boot: 'xdomain', history: history))
      cells = landed.flat_map do |landing|
        landing.benchmarks.map do |declared|
          [suite_cell_name(landing.boot, declared.name), outcome_cell(landing.outcome, benchmark: declared.name)]
        end
      end
      { cells: suite_cells.to_h { |cell| [cell, 'pending'] }.merge(cells.to_h),
        notes: landed.flat_map { |landing| landing_notes(landing.label, landing.outcome) } }
    end

    # The benchmarks with landing cells in boot, in the suite's order.
    def booted(boot) = benchmarks.values.select { |declared| declared.landing.key?(boot) }

    # A landing's outcome for what (a benchmark, or the boot's benchmarks) in boot, or
    # { error: } with the message of the failure that ended it.
    def outcome(landing, what, boot:, history:)
      landing.call(what, boot: BOOTS.fetch(boot), history: history)
    rescue Error => e
      { error: e.message }
    end
    private_class_method :outcome

    # benchmark's suite cell from its landing's outcome. A landing without seeded runs
    # has no seeds_missed.
    def outcome_cell(outcome, benchmark:)
      case outcome
      in { error: String } then 'failed'
      in { record:, refused: }
        boot_cell(record, benchmark: benchmark, refused: refused, seed_caught: outcome.fetch(:seeds_missed, []).empty?)
      end
    end
    private_class_method :outcome_cell

    # What the report says of one landing, each note escaped for the terminal: a refusal
    # never quotes a guest's line but may carry JsonInput's words about it, and a
    # failure's message may quote the guest's FAILED line. A boot that ran to its end has
    # no timed_out.
    def landing_notes(label, outcome)
      notes = case outcome
              in { error: String => error } then ["failed: #{error}"]
              in { record:, written:, refused: }
                kept = written ? "recorded #{written}" : "replayed the stored log #{record.run.reused_from}, no record added"
                cells = record.boot.cells.reject { |cell| cell.status == 'measured' }
                              .map { |cell| "#{cell.operation} #{cell.conditions.placement}: #{cell.status} (#{cell.reason})" }
                [kept, *outcome.fetch(:seeds_missed, []).map { |missed| "the seeded #{missed} was not caught" },
                 *[outcome[:timed_out]].compact, *cells, *refused.map { |reason| "refused: #{reason}" }]
              end
      notes.map { |note| "bench: #{label}: #{LineEscape.escape(note)}" }
    end
    private_class_method :landing_notes
  end
end
