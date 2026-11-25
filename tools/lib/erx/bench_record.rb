# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'time'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'git_environment'
require_relative 'json_input'
require_relative 'source_revision'

module Erx
  # One benchmark run's record and its one writer (docs/design-bench.md, "The record").
  # A record separates where the run happened (its Environment, whose name is derived and
  # names the directory) from what ran (its Subject), and holds the run's boots of that
  # subject, each with its own clock and one Cell per operation under one set of
  # conditions. The writer puts it under <history>/bench/<environment>/<run>/ and
  # refuses any destination that is not a separate git repository outside every
  # worktree of the erXos repository, or that a symbolic link would carry elsewhere.
  # Every file name is derived from validated declaration names and the run's own facts,
  # never from a guest's line.
  module BenchRecord
    # The format a record is written in; a record of any other is refused, never read.
    FORMAT = 3
    STATUSES = %w[measured partial timed_out unsupported failed rejected not_run].freeze
    CLOCKS = %w[counter host analyser virtual monotonic cycles].freeze
    PROFILES = %w[fast expensive periodic sustained].freeze
    SYSTEMS = %w[erxos l4re freebsd linux genode-hw].freeze
    # A benchmark, operation, load cell or placement name, as a declaration gives it.
    NAME = /\A[a-z][a-z0-9-]{0,31}\z/
    # A host's hardware model (sysctl hw.model on macOS): no path separator, no space.
    MODEL = /\A[A-Za-z0-9][A-Za-z0-9.,_-]{0,63}\z/
    REVISION = /\A(?:\h{40}|\h{64})\z/
    STARTED_BY = /\A(?:landing|milestone|manual|gate [A-Z][A-Z0-9]{0,7})\z/
    FILE_BYTES = 1 << 20
    LOG_BYTES = 64 << 20
    MANIFEST = 'run.json'
    # The statuses whose cell has no summary (docs/design-bench.md, "The record").
    NO_SUMMARY = %w[timed_out unsupported rejected not_run].freeze
    BOOT_LOGS = %i[serial qemu].freeze
    KINDS = %w[qemu-hvf qemu-tcg qemu-det pi4 host].freeze
    # A cell's summary form: a histogram of samples, or another system's own program's
    # operation count, total and printed mean (docs/design-bench.md, "A mean").
    FORMS = %w[histogram mean].freeze
    MEAN_FIELDS = %w[count total mean].freeze

    # The percentiles a summary reports, exact so that ceil(p * n) has no rounding error.
    P50 = 1 / 2r
    P99 = 99 / 100r
    P999 = 999 / 1000r
    PERCENTILES = { 'p50' => P50, 'p99' => P99, 'p999' => P999 }.freeze
    # A percentile is reported only with at least this many samples above it.
    ABOVE = 10
    TOO_FEW = { 'unsupported' => 'too few samples' }.freeze
    # A reason: words starting lowercase, no control character, nothing a terminal interprets.
    REASON = /\A[a-z][A-Za-z0-9 ,:_()-]{0,79}\z/

    # A record part that fails a condition. reason names the field, never the value, so
    # a line's validator can say which line it refused.
    class Invalid < Error
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("bench record: #{reason}")
      end
    end

    def self.check(valid, what) = valid || raise(Invalid, what)

    # A copy of value and everything it holds, frozen: a record's parts never change once
    # built, and no caller's later change reaches them.
    def self.frozen(value)
      check(json?(value), 'a record part holds a value that is not JSON')
      frozen_copy(value)
    end

    # The copy of a value json? accepted: its strings, arrays and maps are copied and
    # frozen, and its other values are immutable already.
    def self.frozen_copy(value)
      case value
      when String then -value
      when Array then value.map { |item| frozen_copy(item) }.freeze
      when Hash then value.to_h { |key, item| [-key, frozen_copy(item)] }.freeze
      else value
      end
    end
    private_class_method :frozen_copy

    # What a record holds: JSON's values, with string keys and finite numbers.
    def self.json?(value)
      case value
      when String, Integer, true, false, nil then true
      when Float then value.finite?
      when Array then value.all? { |item| json?(item) }
      when Hash then value.all? { |key, item| key.is_a?(String) && json?(item) }
      else false
      end
    end

    def self.plain_hash?(value) = value.is_a?(Hash) && value.keys.all?(String)

    # The range min..max of detail's samples, each extreme inside the histogram bucket that
    # must hold it; nil, with neither given, when the histogram holds no sample.
    def self.extremes(detail)
      histogram = detail.fetch('histogram', [])
      given = detail.slice('min', 'max')
      if histogram.empty?
        check(given.empty?, 'min and max are given without samples')
        return nil
      end
      (first_low, first_last, _), (last_low, last_last, _) = histogram.values_at(0, -1)
      min, max = given.values_at('min', 'max')
      check(min.is_a?(Integer) && max.is_a?(Integer) && min <= max && min.between?(first_low, first_last) &&
            max.between?(last_low, last_last), 'min and max do not lie in the histogram buckets that hold them')
      min..max
    end

    # Whether a one-way cell's uncertainty, where it has one, is at most a tenth of its
    # median, the guest's rule (docs/design-bench.md, "The one clock") held again here.
    # The median is the guest's own (erx_bench_hist_median): the upper end of the bucket
    # holding the sample of rank ceil(n / 2), for any number of samples.
    def self.uncertainty_bounded?(detail)
      uncertainty = detail['uncertainty']
      return true if uncertainty.nil?

      median = median(detail.fetch('histogram', []))
      uncertainty.is_a?(Integer) && !median.nil? && 10 * uncertainty <= median
    end

    # Whether a cell's total, where it has one, is the ticks its samples' batches spanned
    # together (docs/design-bench.md, "Short operations"). Each sample is its batch's ticks
    # over batch, rounded down, so the batches spanned from batch times the samples' sum to
    # that plus batch - 1 a sample, and the histogram's buckets bound the sum. A total of no
    # samples is refused: it is a mean of nothing.
    def self.total_bounded?(detail, batch)
      return true unless detail.key?('total')

      total = detail['total']

      histogram = detail.fetch('histogram', [])
      samples = histogram.sum { |_, _, count| count }
      least = batch * histogram.sum { |low, _, count| low * count }
      most = batch * histogram.sum { |_, last, count| last * count } + samples * (batch - 1)
      total.is_a?(Integer) && samples.positive? && total.between?(least, most)
    end

    # The upper end of the bucket holding the sample of rank ceil(n / 2); nil for none.
    def self.median(histogram)
      rank = (histogram.sum { |_, _, count| count } * P50).ceil
      seen = 0
      histogram.find { |_, _, count| (seen += count) >= rank }&.at(1) unless rank.zero?
    end

    # Buckets [low, last, count] of tick counts, each holding low to last, both included,
    # with a positive count, in ascending order and not overlapping
    # (test/guest/bench/bench_hist.h).
    def self.histogram?(value)
      value.is_a?(Array) &&
        value.all? { |bucket| bucket.is_a?(Array) && bucket.size == 3 && bucket.all?(Integer) } &&
        value.all? { |low, last, count| !low.negative? && low <= last && count.positive? } &&
        value.each_cons(2).all? { |(_, last, _), (low, _, _)| last < low }
    end

    # Where a run happened. kind is one of KINDS; the name is derived from the fields
    # each kind uses, and details (memory, QEMU version, firmware hashes) are recorded
    # beside it and do not name the directory.
    Environment = Data.define(:kind, :model, :cpus, :system, :details) do
      def initialize(kind:, model:, cpus:, system:, details:)
        BenchRecord.check(KINDS.include?(kind), 'environment kind is not one of the kinds')
        BenchRecord.check(model.nil? || (model.is_a?(String) && MODEL.match?(model)), 'machine model is not plain')
        BenchRecord.check(cpus.nil? || (cpus.is_a?(Integer) && cpus.between?(1, 1024)), 'CPU count is not positive')
        BenchRecord.check(system.nil? || SYSTEMS.include?(system), 'system is not one of the systems')
        BenchRecord.check(kind == 'host' ? system.nil? : !system.nil?,
                          kind == 'host' ? 'a host environment runs no guest system' : "a #{kind} environment needs its system")
        BenchRecord.check(BenchRecord.plain_hash?(details), 'environment details are not a map')
        super(kind: kind, model: model, cpus: cpus, system: system, details: BenchRecord.frozen(details))
        name
      end

      # docs/design-bench.md, "Environments": the name carries no host name, and every
      # environment that boots a guest names its system, so two systems never share one.
      def name
        case kind
        when 'qemu-hvf', 'qemu-tcg'
          BenchRecord.check(model && cpus, "#{kind} needs a machine model and a CPU count")
          "#{kind}-#{model}-#{cpus}cpu-#{system}"
        when 'qemu-det' then "qemu-det-#{system}"
        when 'pi4' then "pi4-4gb-#{system}"
        else
          BenchRecord.check(model, 'a host environment needs its machine model')
          "host-#{model}"
        end
      end

      # TCG and deterministic numbers are compared only with their own kind.
      def isolated? = %w[qemu-tcg qemu-det].include?(kind)
    end

    # What ran: the source revision, whether the tree was dirty, and the rest of the
    # subject (image and workload hashes, compiler, flags, manifest) as recorded facts.
    Subject = Data.define(:revision, :dirty, :details) do
      def initialize(revision:, dirty:, details:)
        BenchRecord.check(revision.is_a?(String) && REVISION.match?(revision), 'revision is not a lowercase hash')
        BenchRecord.check([true, false].include?(dirty), 'dirty is not a boolean')
        BenchRecord.check(BenchRecord.plain_hash?(details), 'subject details are not a map')
        super(revision: revision, dirty: dirty, details: BenchRecord.frozen(details))
      end

      # The SHA-256 of the subject as the record writes it: two subjects of one revision,
      # such as two sets a board's walk boots, have different digests.
      def digest = Digest::SHA256.hexdigest(JSON.generate(to_h))
    end

    # When and why the run happened. load is the host's load average before and after,
    # nil where it was not read; reused_from names the run a replayed boot came from;
    # details are the run's other facts, such as a board walk's sensor readings, how it
    # ended, and whether the board and the served link came back to what they were.
    Run = Data.define(:date, :started_by, :load, :host_cpus, :reused_from, :details) do
      def initialize(date:, started_by:, load:, host_cpus:, reused_from:, details:)
        BenchRecord.check(date.is_a?(Time) && date.utc?, 'date is not a UTC time')
        BenchRecord.check(started_by.is_a?(String) && STARTED_BY.match?(started_by), 'started_by is not a known start')
        BenchRecord.check(load.nil? || (load.is_a?(Array) && load.size == 2 &&
                                        load.all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 }),
                          'load is not a before and after pair')
        BenchRecord.check(host_cpus.nil? || (host_cpus.is_a?(Integer) && host_cpus.positive?),
                          'host CPU count is not positive')
        BenchRecord.check(reused_from.nil? || reused_from.is_a?(String), 'reused_from is not a run path')
        BenchRecord.check(BenchRecord.plain_hash?(details), 'run details are not a map')
        super(date: date, started_by: started_by, load: load, host_cpus: host_cpus, reused_from: reused_from,
              details: BenchRecord.frozen(details))
      end

      def replayed? = !reused_from.nil?
    end

    # Everything that makes two cells of one operation the same cell.
    Conditions = Data.define(:load, :placement, :parameters, :clock, :batch) do
      def initialize(load:, placement:, parameters:, clock:, batch:)
        BenchRecord.check([load, placement].all? { |name| name.is_a?(String) && NAME.match?(name) },
                          'load cell or placement is not a declaration name')
        BenchRecord.check(BenchRecord.plain_hash?(parameters), 'workload parameters are not a map')
        BenchRecord.check(CLOCKS.include?(clock), 'clock is not one of the clocks')
        BenchRecord.check(batch.is_a?(Integer) && batch.positive?, 'batch size is not positive')
        super(load: load, placement: placement, parameters: BenchRecord.frozen(parameters), clock: clock, batch: batch)
      end
    end

    # How a cell was sampled: the profile and the sizes it ran at.
    Profile = Data.define(:name, :warmup, :samples, :runs) do
      def initialize(name:, warmup:, samples:, runs:)
        BenchRecord.check(PROFILES.include?(name), 'profile is not one of the profiles')
        BenchRecord.check(warmup.is_a?(Integer) && !warmup.negative?, 'warm-up count is negative')
        BenchRecord.check([samples, runs].all? { |count| count.is_a?(Integer) && count.positive? },
                          'sample or run count is not positive')
        super
      end
    end

    # One operation under one set of conditions. Every status but measured carries its
    # reason, so an unknown, partial, unsupported or timed-out result says why. detail is
    # what the cell's form holds (the operation's file): a histogram's buckets, extremes,
    # largest and raw samples, with its profile and lost, early and missed counts; or a
    # mean's count, total and printed mean, with no profile and no counts, which its
    # program never gave. The summary run.json shows is derived from detail, never
    # supplied beside it.
    Cell = Data.define(:benchmark, :operation, :conditions, :form, :profile, :status, :reason, :counts, :detail) do
      def initialize(benchmark:, operation:, conditions:, profile:, status:, reason:, counts:, detail:, form: 'histogram')
        BenchRecord.check([benchmark, operation].all? { |name| name.is_a?(String) && NAME.match?(name) },
                          'benchmark or operation is not a declaration name')
        BenchRecord.check(conditions.is_a?(Conditions), 'cell conditions are not typed')
        BenchRecord.check(FORMS.include?(form), 'summary form is not histogram or mean')
        BenchRecord.check(STATUSES.include?(status), 'status is not one of the cell statuses')
        BenchRecord.check(status == 'measured' ? reason.nil? : (reason.is_a?(String) && REASON.match?(reason)),
                          'a cell that is not measured needs its reason, in plain words')
        BenchRecord.check(BenchRecord.plain_hash?(detail), 'detail is not a map')
        if form == 'mean'
          BenchRecord.mean!(status: status, profile: profile, counts: counts, detail: detail)
        else
          BenchRecord.histogram!(status: status, profile: profile, counts: counts, detail: detail, batch: conditions.batch)
        end
        super(benchmark: benchmark, operation: operation, conditions: conditions, form: form, profile: profile,
              status: status, reason: reason, counts: counts && BenchRecord.frozen(counts),
              detail: BenchRecord.frozen(detail))
      end

      # What the cell claims, from its detail; a cell whose status has no summary claims
      # nothing. A histogram claims its sample count, extremes, the percentiles the count
      # allows, whether the samples are partial and, where it kept its total, its operation
      # count and that total; a mean its count, total and mean.
      def summary
        return {} if NO_SUMMARY.include?(status)
        return detail.slice(*MEAN_FIELDS) if form == 'mean'
        return BenchRecord.sustained_summary(self) if profile.name == 'sustained'

        histogram = detail.fetch('histogram', [])
        samples = histogram.sum { |_, _, count| count }
        operations = detail.key?('total') ? { 'count' => samples * conditions.batch, 'total' => detail['total'] } : {}
        { 'samples' => samples, 'partial' => status != 'measured' }
          .merge(detail.slice('min', 'max'), BenchRecord.percentiles(histogram), operations)
      end

      def key = [benchmark, operation, conditions]
      def file = BenchRecord.operation_file(benchmark, operation)
    end

    # A histogram cell's shape: its profile, its counts, and buckets that hold every
    # sample a measured cell's profile asked for, none where its status has no summary.
    def self.histogram!(status:, profile:, counts:, detail:, batch:)
      check(profile.is_a?(Profile), 'a histogram cell has no profile')
      check(counts.is_a?(Hash) && counts.keys.sort == %w[early lost missed] &&
            counts.values.all? { |count| count.is_a?(Integer) && !count.negative? },
            'counts are not lost, early and missed')
      check(histogram?(detail.fetch('histogram', [])), 'histogram is not ascending [low, last, count] buckets')
      check(windows?(detail.fetch('windows', [])),
            'windows are not counts by window and thread, the same threads in every window')
      check(profile.name == 'sustained' || !detail.key?('windows'), 'a cell that is not sustained has windows')
      check(status != 'measured' || samples(profile, detail) == profile.samples,
            'a measured cell lacks samples its profile asked for: it holds every sample or is partial')
      extremes(detail)
      check(status != 'measured' || (counts['lost'].zero? && counts['early'].zero?),
            'a cell with a lost wake or an early return is failed, not measured')
      check(!NO_SUMMARY.include?(status) || samples(profile, detail).zero?, "a #{status} cell has no samples")
      check(status != 'measured' || uncertainty_bounded?(detail), 'a measured cell has an uncertainty above a tenth of its median')
      check(total_bounded?(detail, batch), "a total is not the ticks its samples' batches spanned")
    end

    # A mean cell's shape (docs/design-bench.md, "A mean"): no profile and no counts; a
    # measured one holds exactly its operation count, the total over them and the mean
    # its program printed, and any other holds nothing. A total has no samples to be
    # partial of.
    def self.mean!(status:, profile:, counts:, detail:)
      check(profile.nil? && counts.nil?, 'a mean has no profile and no lost, early or missed counts')
      check(status != 'partial', 'a mean is never partial')
      return check(detail.empty?, "a #{status} mean holds no count, total or mean") unless status == 'measured'

      count, total, mean = detail.values_at(*MEAN_FIELDS)
      check(detail.keys.sort == MEAN_FIELDS.sort && count.is_a?(Integer) && count.positive? &&
            total.is_a?(Integer) && total.positive? && mean.is_a?(Numeric) && !mean.negative?,
            'a measured mean is not a positive count, a positive total and a mean')
    end

    # A boot's position in its run: a board entry's in the walk's queue, or 1 for the
    # one boot of a QEMU run.
    POSITIONS = (1..65_535)

    # Where a boot's files lie in its run directory: the directory of its operation files,
    # which also names its logs, and an operation's file of cells within it.
    def self.boot_directory(position) = "boot-#{position}"
    def self.operation_file(benchmark, operation) = "#{benchmark}/#{operation}.json"

    # One boot of a run: its position, its calibration, its cells and the facts only it
    # has, such as a board entry's name, its boot.img SHA-256 and how the walk saw it
    # end. A boot whose cells are all means has no clock group, since their program
    # measures no calibration; any other has its own, empty when it gave no valid CLOCK
    # line. A boot holds each cell once.
    Boot = Data.define(:position, :clock, :cells, :details) do
      def initialize(position:, clock:, cells:, details:)
        BenchRecord.check(position.is_a?(Integer) && POSITIONS.cover?(position), 'boot position is not a queue position')
        BenchRecord.check(cells.is_a?(Array) && !cells.empty? && cells.all?(Cell), 'boot holds no cells')
        if cells.all? { |cell| cell.form == 'mean' }
          BenchRecord.check(clock.nil?, 'a boot of means has no clock group')
        else
          BenchRecord.check(BenchRecord.plain_hash?(clock), 'clock calibration is not a map')
        end
        BenchRecord.check(cells.map(&:key).uniq.size == cells.size, 'boot holds one cell twice')
        BenchRecord.check(BenchRecord.plain_hash?(details), 'boot details are not a map')
        super(position: position, clock: BenchRecord.frozen(clock), cells: cells.dup.freeze, details: BenchRecord.frozen(details))
      end

      # The boot's directory of operation files, and its logs' name before their kind.
      def directory = BenchRecord.boot_directory(position)
      def file(cell) = File.join(directory, cell.file)
    end

    # Where a run happened, what ran, when, and the run's boots of that subject, in
    # ascending positions. Every boot of one subject was asked the same cells, so each
    # holds the same keys, whatever their statuses: a comparison counting the boots of a
    # record that holds its cell finds the cell in each.
    Record = Data.define(:environment, :subject, :run, :boots) do
      def initialize(environment:, subject:, run:, boots:)
        BenchRecord.check(environment.is_a?(Environment) && subject.is_a?(Subject) && run.is_a?(Run),
                          'record parts are not typed')
        BenchRecord.check(boots.is_a?(Array) && !boots.empty? && boots.all?(Boot), 'record holds no boots')
        BenchRecord.check(boots.each_cons(2).all? { |before, after| before.position < after.position },
                          'boots are not in ascending positions, each once')
        BenchRecord.check(boots.map { |boot| boot.cells.map(&:key).to_set }.uniq.size == 1,
                          'boots of one record hold different cells')
        super(environment: environment, subject: subject, run: run, boots: boots.dup.freeze)
      end

      # The keys of the cells every boot holds.
      def keys = boots.first.cells.map(&:key)

      # The one boot of a record that has one, as a QEMU run's record does; a record of
      # several is refused, since which of them is meant is not said.
      def boot
        BenchRecord.check(boots.size == 1, "a record of #{boots.size} boots has no one boot")
        boots.first
      end

      # The run directory's name: UTC time, the revision's first twelve hex digits,
      # -dirty when the tree was, and the subject's digest's first twelve, so that two
      # subjects of one revision a walk boots at one time are two runs.
      def name
        "#{run.date.strftime('%Y%m%dT%H%M%SZ')}-#{subject.revision[0, 12]}#{subject.dirty ? '-dirty' : ''}" \
          "-#{subject.digest[0, 12]}"
      end
    end

    module_function

    # Percentile p of a histogram of [low, last, count] buckets in ascending order, each
    # holding the values from low to last, both included (test/guest/bench/bench_hist.h):
    # the last value of the bucket holding the sample of rank ceil(p * n), with that
    # bucket's width, or TOO_FEW when fewer than ABOVE samples lie above that rank.
    def percentile(histogram, p)
      count = histogram.sum { |_, _, samples| samples }
      rank = (p * count).ceil
      return TOO_FEW unless count - rank >= ABOVE

      seen = 0
      low, last, = histogram.find { |_, _, samples| (seen += samples) >= rank }
      { 'value' => last, 'bucket' => last - low + 1 }
    end

    def percentiles(histogram) = PERCENTILES.transform_values { |p| percentile(histogram, p) }

    WINDOW_COUNTS = %w[iterations longest lost waited].freeze

    # A cell's samples: a sustained cell's windows, any other's histogram's samples.
    def samples(profile, detail)
      return detail.fetch('windows', []).size if profile.name == 'sustained'

      detail.fetch('histogram', []).sum { |_, _, count| count }
    end

    # By window, each thread's counts, the same number of threads in every window.
    def windows?(value)
      value.is_a?(Array) && value.all? { |threads| threads.is_a?(Array) && !threads.empty? } &&
        value.map(&:size).uniq.size <= 1 &&
        value.flatten(1).all? do |kept|
          kept.is_a?(Hash) && kept.keys.sort == WINDOW_COUNTS.sort && kept.values.all? { |count| count.is_a?(Integer) && !count.negative? }
        end
    end

    # A sustained cell's summary (docs/design-bench.md, "A sustained cell"): by window and
    # thread its share of the CPU, its longest gap and its lost turns; by window the
    # smallest share over the largest; and the longest gap over all windows, the statistic
    # a comparison judges, an exact tick count with no bucket. A share is the part of the
    # window a thread was not kept off the CPU for half a slice or more, and none below
    # 0: a lost turn that began before its window counts whole in the window it ended in.
    def sustained_summary(cell)
      windows = cell.detail.fetch('windows', [])
      summary = { 'samples' => windows.size, 'partial' => cell.status != 'measured' }
      return summary if windows.empty?

      ticks = cell.conditions.parameters.fetch('window-ms') * cell.detail.fetch('frequency_hz') / 1000r
      by_window = windows.map do |threads|
        shares = threads.map { |kept| [1 - (kept.fetch('waited') / ticks), 0].max.to_f.round(6) }
        { 'shares' => shares, 'ratio' => shares.max.zero? ? 0.0 : (shares.min / shares.max).round(6),
          'longest' => threads.map { |kept| kept.fetch('longest') }, 'lost' => threads.map { |kept| kept.fetch('lost') } }
      end
      summary.merge('windows' => by_window,
                    'longest' => { 'value' => windows.flatten(1).map { |kept| kept.fetch('longest') }.max })
    end

    # The history repository records are written to: ERX_BENCH_HISTORY, or
    # ~/erxos-history (docs/design-bench.md, "The record").
    def history = ENV.fetch('ERX_BENCH_HISTORY') { File.join(Dir.home, 'erxos-history') }

    # Writes record under history and returns the run directory's real path. logs is
    # none, or one { serial:, qemu: } map of log bytes per boot of the record, in its
    # order, written as boot-<n>.serial.log and boot-<n>.qemu.log for the boot at
    # position n. Everything is serialized and bounded before the directory is made, a
    # bound applying to each file, and run.json is written last, by rename, so a run is
    # complete once it exists.
    def write(record, history:, erxos_root:, logs: [])
      files = serialized(record).merge(boot_logs(record, logs))
      oversized = files.find { |name, bytes| bytes.bytesize > (name.end_with?('.log') ? LOG_BYTES : FILE_BYTES) }
      check(oversized.nil?, "#{oversized&.first} exceeds its size bound")
      destination = Destination.new(history: history, erxos_root: erxos_root)
      run = destination.make_run_directory(['bench', record.environment.name, record.name])
      manifest = files.delete(MANIFEST)
      directories(files.keys).each { |directory| make_directory(run, directory) }
      files.each { |name, bytes| create(run, name, bytes) }
      create(run, "#{MANIFEST}.partial", manifest)
      File.rename(File.join(run, "#{MANIFEST}.partial"), File.join(run, MANIFEST))
      run
    end

    # The record in the run directory run, refused whole if any file is missing, too
    # large, of another format or not a record. Each cell's operation file is derived
    # from its boot's position and its validated names, as the writer derives it, and a
    # manifest naming any other is refused. operations reads each operation file's cells
    # on first use, and once.
    def read(run)
      manifest = parse(File.join(run, MANIFEST))
      operations = Hash.new { |cells, file| cells[file] = parse(File.join(run, file)).fetch('cells') }
      from_h(manifest, operations)
    rescue KeyError, TypeError, NoMethodError, ArgumentError => error
      raise Error, "bench record #{run}: not a record (#{error.class})"
    end

    # The bytes of the boot log at path, as write takes them, within a log's bound.
    def boot_log(path) = BoundedFile.read(path, maximum: LOG_BYTES)

    def parse(path)
      value = JsonInput.parse(BoundedFile.read(path, maximum: FILE_BYTES),
                              max_bytes: FILE_BYTES, label: "bench record #{path}")
      check(value.is_a?(Hash) && value['format'] == FORMAT, "#{path} is not of format #{FORMAT}")
      value
    end

    def serialized(record)
      operations = record.boots.flat_map do |boot|
        boot.cells.group_by { |cell| boot.file(cell) }.map do |file, cells|
          [file, JSON.pretty_generate('format' => FORMAT, 'benchmark' => cells.first.benchmark,
                                      'operation' => cells.first.operation,
                                      'cells' => cells.map { |cell| { 'conditions' => cell.conditions.to_h, 'detail' => cell.detail } })]
        end
      end
      { MANIFEST => JSON.pretty_generate(to_h(record)) }.merge(operations.to_h)
    end

    def boot_logs(record, logs)
      check(logs.empty? || logs.size == record.boots.size, 'boot logs are not one map per boot')
      record.boots.zip(logs).flat_map do |boot, kept|
        kept.to_h.map do |kind, bytes|
          check(BOOT_LOGS.include?(kind), 'a boot log is not serial or qemu')
          check(bytes.is_a?(String), "boot #{boot.position}'s #{kind} log is not bytes")
          ["#{boot.directory}.#{kind}.log", bytes.b]
        end
      end.to_h
    end

    # Every directory names lie in, relative to the run directory, each after its parent.
    def directories(names)
      names.flat_map do |name|
        parts = File.dirname(name).split('/') - ['.']
        (1..parts.size).map { |count| parts.first(count).join('/') }
      end.uniq
    end

    # Makes directory in the run directory, which this writer made exclusively: whatever
    # is already there, a symbolic link above all, was not made by it and is refused.
    def make_directory(run, directory)
      Dir.mkdir(File.join(run, directory), 0o755)
    rescue SystemCallError => error
      raise Error, "bench record: cannot make #{directory}: #{error.class}"
    end

    # Writes name, relative to the run directory, as a new file that is no symbolic link.
    def create(run, name, bytes)
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      File.open(File.join(run, name), flags, 0o644) { |output| output.write(bytes) }
    rescue SystemCallError => error
      raise Error, "bench record: cannot write #{name}: #{error.class}"
    end

    def to_h(record)
      environment, subject, run = record.environment, record.subject, record.run
      { 'format' => FORMAT,
        'environment' => environment.to_h.transform_keys(&:to_s).merge('name' => environment.name),
        'subject' => subject.to_h.transform_keys(&:to_s),
        'run' => run.to_h.transform_keys(&:to_s).merge('date' => run.date.iso8601),
        'boots' => record.boots.map do |boot|
          { 'position' => boot.position, 'details' => boot.details, 'clock' => boot.clock,
            'cells' => boot.cells.map do |cell|
              cell.to_h.except(:detail).transform_keys(&:to_s)
                  .merge('conditions' => cell.conditions.to_h.transform_keys(&:to_s),
                         'profile' => cell.profile&.to_h&.transform_keys(&:to_s), 'summary' => cell.summary,
                         'file' => boot.file(cell))
            end }
        end }
    end

    BOOT_FIELDS = %w[cells clock details position].freeze

    def from_h(manifest, operations)
      boots = manifest.fetch('boots').map do |boot|
        check(boot.keys.sort == BOOT_FIELDS, 'a boot is not its position, details, clock and cells')
        position = boot.fetch('position')
        check(position.is_a?(Integer) && POSITIONS.cover?(position), 'boot position is not a queue position')
        cells = boot.fetch('cells').map do |cell|
          cell_from_h(cell, directory: boot_directory(position), operations: operations)
        end
        Boot.new(position: position, clock: boot.fetch('clock'), cells: cells, details: boot.fetch('details'))
      end
      run = manifest.fetch('run')
      Record.new(environment: Environment.new(**keywords(manifest.fetch('environment'), 'name')),
                 subject: Subject.new(**keywords(manifest.fetch('subject'))),
                 run: Run.new(**keywords(run, 'date'), date: Time.iso8601(run.fetch('date')).utc),
                 boots: boots)
    end

    # A cell the manifest lists in the boot whose directory is given, with its detail
    # from the operation file its names derive, which must be the file it names.
    def cell_from_h(cell, directory:, operations:)
      names = cell.values_at('benchmark', 'operation')
      check(names.all? { |name| name.is_a?(String) && NAME.match?(name) }, 'benchmark or operation is not a declaration name')
      file = File.join(directory, operation_file(*names))
      check(cell.fetch('file') == file, 'a cell names an operation file not derived from it')
      detail = operations[file].find { |entry| entry.fetch('conditions') == cell.fetch('conditions') }
      check(detail, 'an operation file lacks a cell the manifest lists')
      profile = cell.fetch('profile')&.then { |sizes| Profile.new(**keywords(sizes)) }
      Cell.new(**keywords(cell, 'conditions', 'profile', 'summary', 'file'),
               conditions: Conditions.new(**keywords(cell.fetch('conditions'))), profile: profile,
               detail: detail.fetch('detail'))
    end

    # A manifest map without the fields drop names, as keyword arguments.
    def keywords(hash, *drop) = hash.except(*drop).transform_keys(&:to_sym)

    private_class_method :parse, :serialized, :boot_logs, :directories, :make_directory, :create, :to_h, :from_h,
                         :cell_from_h, :keywords

    # The checks on where a record may be written (docs/design-bench.md, "Where records
    # are written"). The history root must exist, be the top of a git work tree whose
    # common git directory is not the erXos repository's, and lie by real path outside
    # every worktree of the erXos repository, and share no root commit with it; the run
    # directory is then made one component at a time from the root, refusing any symbolic link, and its real path
    # must lie under the root's and outside every erXos worktree.
    class Destination
      def initialize(history:, erxos_root:)
        @root = real_path(history, 'history root')
        top = git(@root, 'rev-parse', '--show-toplevel')
        refuse("is not the top of a git work tree: #{@root}") unless top && real_path(top, 'work tree') == @root
        erxos_common = git(erxos_root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        refuse("cannot find the erXos repository at #{erxos_root}") unless erxos_common
        common = git(@root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        refuse("shares the erXos repository's common git directory: #{@root}") if
          real_path(common, 'common git directory') == real_path(erxos_common, 'common git directory')
        refuse("shares a root commit with the erXos repository: #{@root}") unless
          (roots(@root, side: 'history destination') & roots(erxos_root, side: 'the erXos repository')).empty?
        @worktrees = worktrees(erxos_root)
        outside_worktrees(@root)
      end

      # Makes the run directory under the root from components, the last exclusively,
      # and returns its real path.
      def make_run_directory(components)
        *parents, run = components
        parent = parents.reduce(@root) { |path, component| directory(File.join(path, component), exclusive: false) }
        path = directory(File.join(parent, run), exclusive: true)
        real = File.realpath(path)
        refuse("leaves the history root: #{path}") unless real.start_with?("#{@root}/")
        outside_worktrees(real)
      end

      private

      # path, made here when absent (and, when exclusive, only then), if it is a
      # directory and no symbolic link. Its parent is checked first, so nothing is made
      # under a refused prefix.
      def directory(path, exclusive:)
        parent = File.realpath(File.dirname(path))
        refuse("leaves the history root: #{path}") unless parent == @root || parent.start_with?("#{@root}/")
        outside_worktrees(parent)
        made = make_directory(path)
        refuse("run directory already exists: #{path}") if exclusive && !made
        stat = File.lstat(path)
        refuse("is a symbolic link: #{path}") if stat.symlink?
        refuse("is not a directory: #{path}") unless stat.directory?
        path
      end

      def make_directory(path)
        Dir.mkdir(path, 0o755)
        true
      rescue Errno::EEXIST
        false
      end

      def outside_worktrees(path)
        inside = @worktrees.find { |tree| path == tree || path.start_with?("#{tree}/") }
        refuse("lies inside the erXos worktree #{inside}: #{path}") if inside
        path
      end

      # Every worktree git lists for the erXos repository, the main one included, by
      # real path where it still exists.
      def worktrees(erxos_root)
        listing = git(erxos_root, 'worktree', 'list', '--porcelain', '-z', line: false)
        refuse("cannot list the erXos repository's worktrees at #{erxos_root}") unless listing
        listing.split("\0").filter_map { |field| field.delete_prefix('worktree ') if field.start_with?('worktree ') }
               .map { |tree| File.exist?(tree) ? File.realpath(tree) : File.expand_path(tree) }
      end

      # The root commits of every ref in directory, none for a repository with no commit
      # yet. A second clone of erXos has a common git directory of its own but erXos's
      # roots, on whatever branch it has checked out; a shallow clone hides them, so either
      # side shallow is refused, naming that side.
      def roots(directory, side:)
        shallow = git(directory, 'rev-parse', '--is-shallow-repository') != 'false'
        raise Error, "bench record: #{side} is a shallow clone: #{directory}" if shallow

        listing = git(directory, 'rev-list', '--max-parents=0', '--all')
        raise Error, "bench record: cannot list the root commits of #{side} at #{directory}" unless listing
        listing.split("\n")
      end

      def real_path(path, what)
        File.realpath(path)
      rescue SystemCallError
        refuse("#{what} does not exist: #{path}")
      end

      # git's output in directory, or nil when git refuses there.
      def git(directory, *arguments, line: true)
        output, _, status = Open3.capture3(GitEnvironment.isolated, *SourceRevision::GIT, '-C', directory, *arguments,
                                           stdin_data: '')
        return nil unless status.success?

        line ? output.chomp : output
      end

      def refuse(reason) = raise(Error, "bench record: history destination #{reason}")
    end
  end
end
