# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/vt_oracle'
require_relative '../vt/corpus'

# erx_vt against its oracle, libvterm 0.3.3 (docs/design-display.md, "The oracle"):
# test/vt/corpus.rb's cases run through test/vt/vterm_dump.c, built from the fetched
# pin by Erx::VtOracle, and through erx_vt on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies), and the dumps must be equal. A case where they differ
# must be listed in test/vt/differences.txt, as a documented difference or a libvterm
# bug, with erx_vt's dump, which erx_vt must then give exactly; a listed case on which
# they agree is stale and fails too.
class ErxVtOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCE = File.join(ROOT, 'erlang/apps/erx_display/src/erx_vt.erl')
  # A CUP whose column defaults to 2, not 1, which the per-row cases must catch.
  CUP = 'move(VT1, Row, arg(tl_or_empty(Ps), 1))'
  CUP_BROKEN = 'move(VT1, Row, arg(tl_or_empty(Ps), 2))'
  SOURCES = [*%w[erlang/apps/erx_display/src/erx_vt_width.erl erlang/apps/erx/src/generated/erx_present.erl
                  erlang/apps/erx/src/generated/erx_schema.erl]
               .map { |path| Erx::Generated.path(path, root: ROOT) },
             File.join(ROOT, 'test/erlang/erx_vt_oracle.erl')].freeze
  DIFFERENCES = File.join(ROOT, 'test/vt/differences.txt')
  KINDS = %w[documented upstream].freeze
  DEADLINE = '300'
  Entry = Data.define(:kind, :reason, :dump)

  def self.dumps = @dumps ||= dumps_of(File.binread(SOURCE))

  # The corpus through libvterm and through erx_vt compiled from module_text.
  def self.dumps_of(module_text)
    Dir.mktmpdir('erx-vt-oracle') do |work|
      cases = VtCorpus.cases
      script = File.join(work, 'corpus.script')
      File.binwrite(script, VtCorpus.script(cases))
      File.binwrite(File.join(work, 'erx_vt.erl'), module_text)
      { names: cases.map(&:name), oracle: split(oracle(script)), erx_vt: split(erx_vt(script, work)) }
    end
  end

  def self.oracle(script)
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    program = Erx::VtOracle.ensure(root: ROOT, runner: runner)
    output, status = Open3.capture2('gtimeout', '-k', '10', DEADLINE, program, stdin_data: File.binread(script),
                                                                                binmode: true)
    raise "vterm_dump failed: #{status}" unless status.success?

    output
  end

  def self.erx_vt(script, work)
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERLC'), '-Werror', '-o', work,
                                     File.join(work, 'erx_vt.erl'), *SOURCES, stdin_data: '')
    raise "erlc failed: #{output}" unless status.success?

    dumped = File.join(work, 'erx_vt.dumps')
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                     '-eval', 'erx_vt_oracle:main(), halt().', '-extra', script, dumped,
                                     stdin_data: '')
    raise "erx_vt_oracle failed: #{output}" unless status.success? && File.file?(dumped)

    File.binread(dumped)
  end

  def self.split(text) = text.split(/^end\n/).map { |dump| "#{dump}end\n" }

  # The entries of differences.txt by case name: `case NAME`, `kind KIND`, one or
  # more `reason TEXT` lines, `dump`, then erx_vt's dump through its `end`.
  def self.differences
    entries = {}
    lines = File.readlines(DIFFERENCES).reject { |line| line.start_with?('#') || line.strip.empty? }
    until lines.empty?
      name = lines.shift.delete_prefix('case ').chomp
      kind = lines.shift.delete_prefix('kind ').chomp
      reason = []
      reason << lines.shift.delete_prefix('reason ').chomp while lines.first&.start_with?('reason ')
      raise "differences.txt: #{name}: no dump" unless lines.shift == "dump\n"

      dump = []
      dump << lines.shift until dump.last == "end\n" || lines.empty?
      raise "differences.txt: #{name}: dump without end" unless dump.last == "end\n"
      raise "differences.txt: #{name}: unknown kind #{kind}" unless KINDS.include?(kind)
      raise "differences.txt: #{name}: listed twice" if entries.key?(name)

      entries[name] = Entry.new(kind: kind, reason: reason.join(' '), dump: dump.join)
    end
    entries
  end

  def test_erx_vt_and_libvterm_agree_but_for_the_listed_differences
    failures = unexplained(self.class.dumps)
    assert_empty failures, failures.join("\n")
  end

  def test_a_cup_with_the_wrong_default_fails
    source = File.binread(SOURCE)
    raise "erx_vt.erl no longer holds #{CUP}" unless source.include?(CUP)

    failures = unexplained(self.class.dumps_of(source.sub(CUP, CUP_BROKEN)))
    assert(failures.any? { |failure| failure.start_with?('csi-H-none: ') }, failures.join("\n"))
  end

  private

  def unexplained(dumps)
    assert_equal dumps[:names].length, dumps[:oracle].length, 'vterm_dump wrote a dump per case'
    assert_equal dumps[:names].length, dumps[:erx_vt].length, 'erx_vt_oracle wrote a dump per case'
    listed = self.class.differences
    failures = dumps[:names].each_with_index.filter_map do |name, index|
      ours = dumps[:erx_vt][index]
      theirs = dumps[:oracle][index]
      entry = listed[name]
      if entry.nil?
        "#{name}: erx_vt and libvterm differ\n--- erx_vt\n#{ours}--- libvterm\n#{theirs}" unless ours == theirs
      elsif ours == theirs
        "#{name}: listed in differences.txt, but erx_vt and libvterm agree"
      elsif ours != entry.dump
        "#{name}: erx_vt's dump is not the one differences.txt pins\n--- erx_vt\n#{ours}--- pinned\n#{entry.dump}"
      end
    end
    unknown = listed.keys - dumps[:names]
    unknown.map { |name| "#{name}: listed in differences.txt, but not a corpus case" } + failures
  end
end
