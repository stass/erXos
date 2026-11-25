# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'bench_record'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'json_input'

module Erx
  # The two files a board run writes beside its log under build/bench-board/
  # (docs/design-bench.md, "Importing a log"): queue.json, written before the queue is
  # served, which ties each boot name to its entry, and walk.json, written as the walk
  # ends, its outcomes. BoardLog reads a log with them, the live run's and an import's
  # alike. Each type's constructor refuses what is not one, so a file read back is
  # either a whole queue or walk or an Erx::Error naming the file and the field.
  module BoardFiles
    FORMAT = 1
    QUEUE = 'queue.json'
    WALK = 'walk.json'
    # A boot name (docs/design-bench.md, "The construction: the server hands out a queue")
    # and a banner's build and index hash, the handoff's sizes.
    NAME = /\A[0-9a-f]{32}\z/
    BUILD = /\A[0-9a-f]{16}\z/
    SHA256 = /\A[0-9a-f]{64}\z/

    def self.need(valid, what) = valid || raise(Error, "board files: #{what}")

    # What a banner names: the archive header's build and index hash.
    Identity = Data.define(:build, :index) do
      def initialize(build:, index:)
        BoardFiles.need(build.is_a?(String) && BUILD.match?(build), 'a build is not sixteen lowercase hexadecimal digits')
        BoardFiles.need(index.is_a?(String) && SHA256.match?(index), 'an index hash is not a SHA-256')
        super
      end
    end

    # A boot set of the queue: the directory its build record lies in, and that record's
    # SHA-256, so a record made later reads the firmware hashes of the record the entries
    # were made from.
    BootSet = Data.define(:directory, :record_sha256) do
      def initialize(directory:, record_sha256:)
        BoardFiles.need(directory.is_a?(String) && !directory.empty?, 'a set names no directory')
        BoardFiles.need(record_sha256.is_a?(String) && SHA256.match?(record_sha256), "a set's record hash is not a SHA-256")
        super
      end
    end

    # A bench entry: its position in the queue, from 1, its boot name, the index of its
    # set in the queue's sets, and its boot.img's SHA-256.
    Entry = Data.define(:position, :name, :set, :image_sha256) do
      def initialize(position:, name:, set:, image_sha256:)
        BoardFiles.need(position.is_a?(Integer) && position.positive?, 'an entry position is not positive')
        BoardFiles.need(name.is_a?(String) && NAME.match?(name), 'a boot name is not thirty-two lowercase hexadecimal digits')
        BoardFiles.need(set.is_a?(Integer) && !set.negative?, 'an entry names no set')
        BoardFiles.need(image_sha256.is_a?(String) && SHA256.match?(image_sha256), "an entry's image hash is not a SHA-256")
        super
      end
    end

    # A queue: the benchmark its sets run, its sets, its bench entries in position order
    # (the found pair, the queue's last entry, is not one of them), and the found pair's
    # return identity, nil when unknown.
    Queue = Data.define(:benchmark, :sets, :entries, :return_identity) do
      def initialize(benchmark:, sets:, entries:, return_identity:)
        BoardFiles.need(benchmark.is_a?(String) && BenchRecord::NAME.match?(benchmark), 'the benchmark is not a name')
        BoardFiles.need(sets.is_a?(Array) && !sets.empty? && sets.all?(BootSet), 'the queue holds no sets')
        BoardFiles.need(entries.is_a?(Array) && !entries.empty? && entries.all?(Entry), 'the queue holds no entries')
        BoardFiles.need(entries.map(&:position) == (1..entries.size).to_a, 'the entries are not numbered from 1 in order')
        BoardFiles.need(entries.map(&:name).uniq.size == entries.size, 'a boot name repeats')
        BoardFiles.need(entries.all? { |entry| entry.set < sets.size }, 'an entry names a set the queue does not hold')
        BoardFiles.need(return_identity.nil? || return_identity.is_a?(Identity), 'the return identity is not one')
        super(benchmark: benchmark, sets: sets.freeze, entries: entries.freeze, return_identity: return_identity)
      end

      def entry(name) = entries.find { |entry| entry.name == name }
    end

    # What the board booted after the last entry (docs/design-bench.md, "The record of a
    # board run"): booted, unexpected with the banner's identity, unknown, or not_seen.
    RETURNS = %w[booted unexpected unknown not_seen].freeze
    Returned = Data.define(:status, :identity) do
      def initialize(status:, identity: nil)
        BoardFiles.need(RETURNS.include?(status), 'a return is not one of the returns')
        BoardFiles.need(identity.nil? == (status != 'unexpected'), 'only an unexpected return names an identity')
        BoardFiles.need(identity.nil? || identity.is_a?(Identity), 'the return identity is not one')
        super
      end
    end

    # How a walk ended (docs/design-bench.md, "The walk"), and what each entry was to it:
    # ended, its done or deadline line read; ended_unseen, the next entry began before its
    # end line; stopped, running when the walk ended for the walk's ending; not_run, never
    # begun.
    ENDINGS = %w[returned booted_again halted end_deadline boot_deadline byte_limit console_closed interrupted].freeze
    # The endings that can stop an entry while it runs: the end deadline, whose entry's
    # unreported cells are timed_out, and these, whose entry's are not_run for the reason.
    STOPPED_BY = { 'booted_again' => 'the walk ended: the board booted an entry again',
                   'halted' => 'the walk ended: the board halted',
                   'byte_limit' => 'the walk ended: the boot passed its byte limit',
                   'console_closed' => 'the walk ended: the console closed',
                   'interrupted' => 'the walk ended: the run was interrupted' }.freeze
    STOPPING = ['end_deadline', *STOPPED_BY.keys].freeze
    OUTCOMES = %w[ended ended_unseen stopped not_run].freeze

    # A walk's outcomes: one per bench entry in position order, its ending, restored
    # (whether the link named the found target again, on the host), and returned.
    Walk = Data.define(:outcomes, :ending, :restored, :returned) do
      def initialize(outcomes:, ending:, restored:, returned:)
        BoardFiles.need(outcomes.is_a?(Array) && !outcomes.empty? && outcomes.all? { |outcome| OUTCOMES.include?(outcome) },
                        'an outcome is not one of the outcomes')
        BoardFiles.need(ENDINGS.include?(ending), 'the ending is not one of the endings')
        stopped = outcomes.count('stopped')
        BoardFiles.need(stopped <= 1 && (stopped.zero? || STOPPING.include?(ending)), 'a stopped entry does not match the ending')
        BoardFiles.need([true, false].include?(restored), 'restored is not a boolean')
        BoardFiles.need(returned.is_a?(Returned), 'returned is not a return')
        super(outcomes: outcomes.freeze, ending: ending, restored: restored, returned: returned)
      end

      # The walk's outcome for the entry at position.
      def outcome(position) = outcomes.fetch(position - 1)
    end

    module_function

    def queue_json(queue)
      JSON.pretty_generate('format' => FORMAT, 'benchmark' => queue.benchmark,
                           'sets' => queue.sets.map { |set| set.to_h.transform_keys(&:to_s) },
                           'entries' => queue.entries.map { |entry| entry.to_h.transform_keys(&:to_s) },
                           'return_identity' => queue.return_identity&.to_h&.transform_keys(&:to_s))
    end

    def walk_json(walk)
      JSON.pretty_generate('format' => FORMAT, 'outcomes' => walk.outcomes, 'ending' => walk.ending,
                           'restored' => walk.restored,
                           'returned' => { 'status' => walk.returned.status,
                                           'identity' => walk.returned.identity&.to_h&.transform_keys(&:to_s) })
    end

    # Writes queue's file, or walk's, into directory; a file already there is refused.
    def write_queue(directory, queue) = write(File.join(directory, QUEUE), queue_json(queue))
    def write_walk(directory, walk) = write(File.join(directory, WALK), walk_json(walk))

    def write(path, text) = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write("#{text}\n") }

    # The queue file at path (Queue).
    def read_queue(path)
      keywords(parsed(path)) => { benchmark:, sets: Array => sets, entries: Array => entries, return_identity: identity, **nil }
      Queue.new(benchmark: benchmark, sets: sets.map { |set| BootSet.new(**keywords(set)) },
                entries: entries.map { |entry| Entry.new(**keywords(entry)) }, return_identity: identity && Identity.new(**keywords(identity)))
    rescue NoMatchingPatternError, ArgumentError, TypeError
      raise Error, "board files: #{path} is not a queue file"
    end

    # The walk file at path (Walk).
    def read_walk(path)
      keywords(parsed(path)) => { outcomes:, ending:, restored:, returned:, **nil }
      keywords(returned) => { status:, identity:, **nil }
      Walk.new(outcomes: outcomes, ending: ending, restored: restored,
               returned: Returned.new(status: status, identity: identity && Identity.new(**keywords(identity))))
    rescue NoMatchingPatternError, ArgumentError, TypeError
      raise Error, "board files: #{path} is not a walk file"
    end

    def parsed(path)
      value = JsonInput.parse(BoundedFile.read(path, maximum: BenchRecord::FILE_BYTES), max_bytes: BenchRecord::FILE_BYTES,
                                                                                         label: path)
      need(value.is_a?(Hash) && value['format'].eql?(FORMAT), "#{path} is not of format #{FORMAT}")
      value.except('format')
    end

    # A JSON object's fields as keywords; an unknown field is an ArgumentError of the
    # constructor, which the readers refuse.
    def keywords(object) = object.is_a?(Hash) ? object.transform_keys(&:to_sym) : raise(TypeError)

    private_class_method :parsed, :keywords, :write
  end
end
