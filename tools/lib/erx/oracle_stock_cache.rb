# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'securerandom'
require 'time'
require_relative 'bounded_file'
require_relative 'json_input'
require_relative 'oracle_comparison'

module Erx
  # Stock OTP's per-suite results, kept between oracle runs. Stock's side of a
  # comparison depends only on the stock build and the suites it runs, not on
  # erXos's tree, so a suite whose key is cached is not run on stock again.
  #
  # A suite's key is the SHA-256 of what its stock results depend on
  # (OracleStockCache.key): the stock build's identity from its receipt (OTP
  # version, source hash, flavour, configure flags without the install
  # prefix, compilers, build flags), the host's CPU and OS, stock's
  # scheduler count, the group and suite names, and a digest of the files
  # the run reads (the group's whole test directory, the reporter's sources
  # and the host code that starts stock and reads its events). A change to
  # one of them is a different key, so the old entry is never read again.
  # The key cannot name which other suites shared the stock node, so a
  # suite's cached result may come from a run beside other suites.
  #
  # Entries are one JSON file per key in one directory on the host
  # (ERX_ORACLE_STOCK_CACHE, by default the user's cache directory), shared
  # by every worktree. Each is written whole to a temporary name and renamed,
  # so a reader sees a whole entry or none, and two gates storing the same
  # key at once store the same results. Only suites of a complete stock run
  # are stored. ERX_ORACLE_FRESH_STOCK=1 skips the lookup, so every suite
  # runs on stock again and its entry is replaced.
  class OracleStockCache
    FORMAT = 1
    ENTRY_BYTES = 64 * 1024 * 1024
    # The statuses a complete run's case can have.
    STATUSES = [*OracleComparison::STATUSES, *OracleComparison::UNRESOLVED_STATUSES].freeze

    # A cached suite: its cases (CaseKey to status), when its stock run
    # ended, and its key.
    Entry = Data.define(:suite, :cases, :run_at, :key)

    # The cache the environment names: its directory, and whether lookups
    # are skipped.
    def self.from_environment(env: ENV)
      base = env['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache')
      new(directory: env['ERX_ORACLE_STOCK_CACHE'] || File.join(base, 'erxos/oracle-stock'),
          fresh: env['ERX_ORACLE_FRESH_STOCK'] == '1')
    end

    # What identifies a stock build, from its receipt (build.json): the
    # install prefix names the worktree and is left out, so every worktree's
    # build of the same source and configuration shares entries.
    def self.build_identity(build)
      { 'version' => build.fetch('version'), 'source_sha256' => build.fetch('source_sha256'),
        'flavour' => build.fetch('flavour'),
        'configure' => build.fetch('configure').reject { |flag| flag.start_with?('--prefix=') },
        'compiler' => build.dig('compiler', 'identity'), 'cxx' => build.dig('cxx', 'identity'),
        'build_environment' => build['build_environment'],
        'host' => "#{RbConfig::CONFIG['host_cpu']}-#{RbConfig::CONFIG['host_os']}" }
    end

    # The SHA-256 over `paths`, each file's name relative to `base` and its
    # contents, in name order, so moving, adding or changing a file changes it.
    def self.files_digest(base, paths)
      paths.sort.each_with_object(Digest::SHA256.new) do |path, digest|
        digest << path.delete_prefix("#{base}/") << "\0" << Digest::SHA256.file(path).hexdigest << "\n"
      end.hexdigest
    end

    # A suite's key: `identity` (build_identity), `schedulers` (nil for
    # ERTS's default), `inputs` (files_digest of what the run reads).
    def self.key(identity:, schedulers:, inputs:, group:, suite:)
      Digest::SHA256.hexdigest(JSON.generate([FORMAT, identity, schedulers, inputs, group, suite]))
    end

    attr_reader :directory

    def initialize(directory:, fresh: false)
      @directory = directory
      @fresh = fresh
    end

    # The entry of `suite` stored under `key`, or nil when there is none, the
    # lookup is skipped, or the file is not a whole entry of this format, key
    # and suite with known statuses.
    def find(key, suite:)
      return nil if @fresh

      path = path(key)
      return nil unless File.file?(path)

      record = JsonInput.parse(BoundedFile.read(path, maximum: ENTRY_BYTES), max_bytes: ENTRY_BYTES,
                                                                              label: 'stock cache entry')
      return nil unless record.is_a?(Hash) && record['format'] == FORMAT && record['key'] == key &&
                        record['suite'] == suite && record['cases'].is_a?(Array)

      Entry.new(suite: suite, cases: record['cases'].to_h { |row| case_of(row, suite: suite) },
                run_at: record.fetch('run_at'), key: key)
    rescue Error, KeyError, TypeError, NoMatchingPatternError, SystemCallError
      nil
    end

    # Stores `cases` (CaseKey to status) of `suite` under `key`, run at `run_at`.
    def store(key, suite:, cases:, run_at:)
      FileUtils.mkdir_p(@directory, mode: 0o700)
      rows = cases.map { |name, status| [name.group, name.testcase, name.attempt, status] }
      staged = File.join(@directory, ".#{key}.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(staged, JSON.generate({ 'format' => FORMAT, 'key' => key, 'suite' => suite, 'run_at' => run_at,
                                         'cases' => rows }))
      File.rename(staged, path(key))
    ensure
      FileUtils.rm_f(staged) if staged
    end

    private

    def path(key) = File.join(@directory, "#{key}.json")

    def case_of(row, suite:)
      row => [Array | nil => group, String => testcase, Integer => attempt, String => status]
      raise Error, "unknown status #{status}" unless STATUSES.include?(status)

      [OracleComparison::CaseKey.new(suite: suite, group: group, testcase: testcase, attempt: attempt), status]
    end
  end
end
