# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'
require_relative 'bounded_file'
require_relative 'build_memo'
require_relative 'error'
require_relative 'json_input'

module Erx
  # How the QEMU gate skips a boot that already passed on the same inputs
  # (docs/design-build.md, "Reusing passing boots").
  #
  # What a guest prints depends on what QEMU is handed. A boot key is the
  # SHA-256 over all of it: QEMU's arguments with every input file (image,
  # initrd, device tree) replaced by its SHA-256 and the run's own paths by
  # fixed names, the transcript the harness watches and types from, whether
  # the guest must end the machine, QEMU itself as the build memo names a
  # program (its real path, its content, its install's libraries and the
  # operating system's release), and the harness digest, the build memo's
  # over tools/erx and every file under tools/lib, the suite files included.
  # No path of an input or of the run enters the key, so the same image
  # built in another worktree on the same host has the same key. The host's
  # CPU model is not in it: a store belongs to one host.
  #
  # Only a boot that those inputs determine is reusable. A boot with a disk,
  # a network device, a host link socket or a host link session talks to the
  # host or leaves state its caller reads afterwards, so it always runs.
  #
  # The gate opens one Session per run, and Session#suite makes a SuiteBoots
  # the active one while a suite runs. Inside it Qemu#run looks each reusable
  # boot up. On a hit QEMU does not start: the stored serial log is written
  # into the run's directory, replayed through today's transcript, and
  # returned with the stored timings and 'reused_from' naming the stored log,
  # so the suite judges it with today's code as it would a fresh one. A
  # fresh boot that completed its transcript is held, its log's bytes read at
  # once, until its suite's verdict. SuiteBoots#close records the held boots
  # only when the suite passed; when it did not, it also forgets the records
  # the suite reused, so its next run boots again.
  #
  # The store is local developer state. A record only lets the gate skip a
  # boot; nothing in it feeds a build or an image. Whoever can write the
  # store can forge a pass, as whoever can write the tree can; the checks
  # below guard against damage, not against that writer. A record that does
  # not parse, names another key, holds an impossible time, or whose log is
  # missing, unreadable, too large or no longer has the recorded digest is a
  # miss with a diagnostic, never a hit and never a crash.
  module QemuReuse
    FORMAT = 'erx-qemu-boot-1'
    MAX_RECORD_BYTES = 64 * 1024
    MAX_LOG_BYTES = 64 * 1024 * 1024
    # The store a gate uses unless ERX_QEMU_RESULTS names another, for
    # instance one directory that several worktrees share.
    DEFAULT_STORE = 'build/qemu-results'

    # A record the store holds but cannot vouch for.
    class MalformedRecord < Error; end

    # A stored passing boot: its log's path in the store and the bytes read
    # and checked from it, and the checkpoints and elapsed time the passing
    # run observed.
    Hit = Data.define(:serial, :bytes, :checkpoints, :elapsed_seconds)

    # What one suite's boots were: how many ran, the stored logs of those
    # reused, and why a record was not used or not written.
    Boots = Data.define(:fresh, :reused, :diagnostics) do
      def initialize(fresh: 0, reused: [], diagnostics: [])
        super(fresh: fresh, reused: reused.dup.freeze, diagnostics: diagnostics.dup.freeze)
      end
    end
    NO_BOOTS = Boots.new

    module_function

    # The digest of the harness code a gate run's boots are keyed by.
    def harness_digest(root) = BuildMemo.tools_digest(root: root)

    # QEMU as BuildMemo.program_identity names it, found as Runner finds a
    # program: a name with a slash as a path, a bare name on PATH. Nil when
    # it is not there, so the boot runs and fails as it would.
    def qemu_identity(program)
      path = if program.include?('/') then File.expand_path(program)
             else ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, program) }
                     .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
             end
      path && File.file?(path) ? BuildMemo.program_identity(path) : nil
    end

    # The key of one boot. plan is QemuPlan.argv's output for the boot's
    # inputs by digest; checkpoints is the transcript as Qemu#run takes it.
    # Each field is length-prefixed, so no two field lists share a key.
    def boot_key(plan:, checkpoints:, machine_end:, qemu:, harness:)
      fields = [FORMAT, *plan, *checkpoints.flat_map { |point| checkpoint_fields(point) },
                machine_end.to_s, qemu, harness]
      Digest::SHA256.hexdigest(fields.map { |field| "#{field.bytesize}:#{field.b}" }.join)
    end

    # A verifier is code, which the harness digest covers; the key notes only
    # that the checkpoint has one.
    def checkpoint_fields(point)
      pattern = point.fetch(:pattern)
      [point.fetch(:name), pattern.source, pattern.options.to_s, point.fetch(:seconds).to_s,
       point.fetch(:type, ''), point.key?(:verify) ? 'verify' : '']
    end
    private_class_method :checkpoint_fields

    # The suite whose boots Qemu#run reports to, or nil outside the gate: a
    # boot, a bench or a single test run never reuses anything.
    def active = @active

    # Makes boots the active suite's while the block runs.
    def activate(boots)
      raise Error, 'QEMU reuse: a suite is already active' if @active

      @active = boots
      yield
    ensure
      @active = nil if @active.equal?(boots)
    end

    # One file per record, <key>.json, beside the serial log it vouches for,
    # <key>.log, both owner-only. Both are written under temporary names and
    # renamed into place, the log first, so a record never names a log not
    # yet whole.
    class Store
      KEY = /\A\h{64}\z/

      attr_reader :directory

      def initialize(directory:)
        @directory = File.expand_path(directory)
      end

      # The stored passing boot of key, or nil when none is stored. Raises
      # MalformedRecord for a record it cannot vouch for. The log is read
      # once, bounded, and those bytes are both checked and returned.
      def find(key)
        path = record_path(key)
        return nil unless File.exist?(path)

        record = parse(path)
        validate(record, key: key, path: path)
        bytes = read_log(key, path: path)
        raise MalformedRecord, "#{path}: its serial log changed" unless Digest::SHA256.hexdigest(bytes) == record.fetch('serial_sha256')

        Hit.new(serial: log_path(key), bytes: bytes, checkpoints: record.fetch('checkpoints'),
                elapsed_seconds: record.fetch('elapsed_seconds'))
      end

      # Stores a passing boot: the bytes of its serial log, read when it was
      # held, the path they came from, and what the run observed.
      def record(key:, suite:, source:, bytes:, checkpoints:, elapsed_seconds:)
        FileUtils.mkdir_p(@directory, mode: 0o700)
        temporary = "#{record_path(key)}.#{Process.pid}.#{Random.bytes(4).unpack1('H*')}"
        record = { 'format' => FORMAT, 'key' => key, 'suite' => suite, 'recorded_at' => Time.now.utc.iso8601,
                   'source_log' => source, 'serial_sha256' => Digest::SHA256.hexdigest(bytes),
                   'checkpoints' => checkpoints, 'elapsed_seconds' => elapsed_seconds }
        write_private("#{temporary}.log", bytes)
        write_private("#{temporary}.json", JSON.pretty_generate(record) + "\n")
        File.rename("#{temporary}.log", log_path(key))
        File.rename("#{temporary}.json", record_path(key))
      ensure
        FileUtils.rm_f(["#{temporary}.log", "#{temporary}.json"]) if temporary
      end

      # Removes the record of key, so its boot runs again.
      def forget(key) = FileUtils.rm_f([record_path(key), log_path(key)])

      private

      def record_path(key) = File.join(@directory, "#{checked(key)}.json")

      def log_path(key) = File.join(@directory, "#{checked(key)}.log")

      def checked(key)
        raise Error, 'QEMU reuse: a boot key is 64 hex digits' unless key.is_a?(String) && key.match?(KEY)

        key
      end

      def write_private(path, bytes)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |output| output.binmode.write(bytes) }
      end

      # JsonInput's refusals never quote the record, so no stored byte
      # reaches the terminal through a diagnostic.
      def parse(path)
        JsonInput.parse(BoundedFile.read(path, maximum: MAX_RECORD_BYTES), max_bytes: MAX_RECORD_BYTES, label: 'QEMU boot record')
      rescue Error, SystemCallError => e
        raise MalformedRecord, "#{path}: #{e.message.lines.first.to_s.strip}"
      end

      def read_log(key, path:)
        BoundedFile.read(log_path(key), maximum: MAX_LOG_BYTES)
      rescue Error, SystemCallError => e
        raise MalformedRecord, "#{path}: its serial log: #{e.message.lines.first.to_s.strip}"
      end

      def validate(record, key:, path:)
        why = if !record.is_a?(Hash) then 'not an object'
              elsif record['format'] != FORMAT then 'another format'
              elsif record['key'] != key then 'another key'
              elsif !record['serial_sha256'].is_a?(String) || !record['serial_sha256'].match?(KEY) then 'no log digest'
              elsif !time?(record['elapsed_seconds']) then 'no elapsed time'
              elsif !observed?(record['checkpoints']) then 'no observed checkpoints'
              end
        raise MalformedRecord, "#{path}: #{why}" if why
      end

      def time?(value) = value.is_a?(Numeric) && value.finite? && !value.negative?

      def observed?(checkpoints)
        checkpoints.is_a?(Array) && checkpoints.all? do |point|
          point.is_a?(Hash) && point.keys.sort == %w[elapsed_seconds name] &&
            point['name'].is_a?(String) && time?(point['elapsed_seconds'])
        end
      end
    end

    # One gate run's reuse: the store, the harness digest, and whether every
    # boot must run (fresh).
    class Session
      attr_reader :store, :harness

      def initialize(store:, harness:, fresh: false)
        @store = store
        @harness = harness
        @fresh = fresh
      end

      def fresh? = @fresh

      # Runs the block as suite name with a SuiteBoots of its own active, and
      # returns the block's value and that SuiteBoots, for the caller to close
      # once it knows the suite's verdict.
      def suite(name)
        boots = SuiteBoots.new(session: self, name: name)
        [QemuReuse.activate(boots) { yield }, boots]
      end
    end

    # One suite's boots. A Qemu#run keeps the SuiteBoots active when it
    # began, so a boot is counted and held only under its own suite. Several
    # threads of one suite may report at once, so the state is locked, and a
    # boot reported after close, which its suite never judged, is dropped
    # with a diagnostic.
    class SuiteBoots
      Held = Data.define(:key, :source, :bytes, :checkpoints, :elapsed_seconds)

      attr_reader :harness

      def initialize(session:, name:)
        @session = session
        @store = session.store
        @harness = session.harness
        @name = name
        @lock = Mutex.new
        @fresh = 0
        @reused = []
        @diagnostics = []
        @held = []
        @closed = false
      end

      # The stored boot of key, or nil when the session runs fresh, none is
      # stored, or the record is malformed, which leaves a diagnostic.
      def find(key)
        return nil if @session.fresh?

        @store.find(key)
      rescue MalformedRecord => e
        diagnose("record #{e.message}; the boot runs fresh")
        nil
      end

      def reused(key, hit) = while_open('a reused boot') { @reused << [key, hit.serial] }

      def ran = while_open('a fresh boot') { @fresh += 1 }

      # A fresh boot of key that completed its transcript. Its log is read
      # now, so what is recorded is what this boot wrote, whatever later
      # happens to the path.
      def hold(key:, serial:, report:)
        bytes = BoundedFile.read(serial, maximum: MAX_LOG_BYTES)
        held = Held.new(key: key, source: serial, bytes: bytes, checkpoints: report.fetch('checkpoints').map(&:dup),
                        elapsed_seconds: report.fetch('elapsed_seconds'))
        while_open('a passing boot') { @held << held }
      rescue Error, SystemCallError => e
        diagnose("could not hold the passing boot #{serial}: #{e.message}")
      end

      def diagnose(text) = @lock.synchronize { @diagnostics << text }

      # The suite's Boots once its verdict is known: a suite that passed
      # records its held boots; one that did not forgets the records it
      # reused.
      def close(passed:)
        held, reused = @lock.synchronize do
          @closed = true
          [@held.dup, @reused.dup]
        end
        passed ? record_held(held) : forget_reused(reused.map(&:first).uniq)
        @lock.synchronize { Boots.new(fresh: @fresh, reused: reused.map(&:last), diagnostics: @diagnostics) }
      end

      private

      def while_open(what)
        @lock.synchronize do
          next yield unless @closed

          @diagnostics << "#{what} reported after #{@name} ended was dropped"
        end
      end

      def record_held(held)
        held.each do |boot|
          @store.record(key: boot.key, suite: @name, source: boot.source, bytes: boot.bytes,
                        checkpoints: boot.checkpoints, elapsed_seconds: boot.elapsed_seconds)
        rescue SystemCallError, IOError => e
          diagnose("could not record a passing boot in #{@store.directory}: #{e.message}")
        end
      end

      def forget_reused(keys)
        keys.each do |key|
          @store.forget(key)
        rescue SystemCallError => e
          diagnose("could not forget a reused boot in #{@store.directory}: #{e.message}")
        end
      end
    end
  end
end
