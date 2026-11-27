# frozen_string_literal: true

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

# Runs test/erlang/erx_serves_tests.erl: erx_serves, the reader of a domain's declaration
# of the services it serves, and the storage domain's littlefs, which starts a tree's
# mint only where the declaration names it (docs/design-system.md, "The declaration"),
# against the domain service's mint core. Each fault of FAULTS replaces one passage of
# one source, and the case it names must fail.
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

class ErxServesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  READER = 'erlang/apps/erx/src/erx_serves.erl'
  STORAGE = 'erlang/apps/erx_storage/src/erx_lfs_sup.erl'
  APPLICATIONS = %w[erx erx_files erx_blk erx_storage erx_domain].freeze
  TESTS = %w[test/erlang/erx_serves_tests.erl].freeze

  Fault = Data.define(:name, :source, :from, :to, :caught_by)

  FAULTS = [
    Fault.new(name: 'littlefs mints every tree again', source: STORAGE,
              from: 'lists:member({atom_to_binary(Tree), ?ERX_SERVICE_FILES}, Declaration)', to: 'is_list(Declaration)',
              caught_by: 'a_storage_row_lacking_home_keeps_its_other_providers_test'),
    Fault.new(name: 'the first of several occurrences taken', source: READER,
              from: 'parse({ok, [Words]}) -> pairs(Words);', to: 'parse({ok, [Words | _]}) -> pairs(Words);',
              caught_by: 'anything_but_one_occurrence_fails_the_start_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = File.read(File.join(ROOT, fault.source))
      assert_equal 1, text.scan(fault.from).size, fault.name
      output, status = eunit({ fault.source => text.sub(fault.from, fault.to) })
      refute status.success?, fault.name
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_serves_tests: ).)*?\*failed\*/m, output, fault.name)
    end
  end

  private

  # Compiles the applications with replaced's sources in place of theirs, and the suite,
  # and runs the suite.
  def eunit(replaced)
    Dir.mktmpdir('erx-serves-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_serves_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
