# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_wm_tests.erl, erx_wctl_tests.erl and erx_winctl_tests.erl, the EUnit cases
# of the window policies and of the wctl and ctl text (docs/design-display.md, "Verification and
# testing", the window system), against the erx_display application compiled from source
# with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies). Each property is then run against a copy of a policy with one rule broken,
# which must fail it under the property's name.
class ErxWmTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE_DIRECTORY = 'erlang/apps/erx_display/src'
  TESTS = %w[erx_wm_tests erx_wctl_tests erx_winctl_tests].freeze
  DEADLINE = '300'
  # A broken rule: the file, its text, what replaces it, and the property that must fail,
  # by the name the cases raise.
  Mutant = Data.define(:file, :text, :broken, :property)
  MUTANTS = {
    every_window_shown: Mutant.new(file: 'erx_wm_single.erl',
                                   text: 'state := case WindowId of ShownId -> shown; _ -> hidden end}',
                                   broken: 'state := shown}',
                                   property: /more_than_one_shown/),
    every_window_hidden: Mutant.new(file: 'erx_wm_single.erl',
                                    text: 'state := case WindowId of ShownId -> shown; _ -> hidden end}',
                                    broken: 'state := hidden}',
                                    property: /app_window_not_shown/),
    newest_window_shown: Mutant.new(file: 'erx_wm_single.erl',
                                    text: 'Ids -> lists:min(Ids)',
                                    broken: 'Ids -> lists:max(Ids)',
                                    property: /app_window_not_shown/),
    chord_unrecognised: Mutant.new(file: 'erx_wm.erl',
                                   text: '{false, true} -> {chord, Next',
                                   broken: '{false, true} -> {pass, Next',
                                   property: /chord_delivered/),
    keys_dropped: Mutant.new(file: 'erx_wm_single.erl',
                             text: '{pass, Id} -> {to, Id, Input}',
                             broken: '{pass, _} -> drop',
                             property: /key_not_delivered/)
  }.freeze

  def test_policy_and_wctl_cases_pass_under_eunit
    output, status = eunit(nil)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_showing_every_application_window_fails_the_single_property = assert_mutant_fails(:every_window_shown)

  def test_hiding_every_window_fails_the_single_property = assert_mutant_fails(:every_window_hidden)

  def test_showing_the_newest_window_fails_the_single_property = assert_mutant_fails(:newest_window_shown)

  def test_an_unrecognised_chord_fails_the_chord_property = assert_mutant_fails(:chord_unrecognised)

  def test_dropped_keys_fail_the_delivery_property = assert_mutant_fails(:keys_dropped)

  private

  def assert_mutant_fails(name)
    mutant = MUTANTS.fetch(name)
    output, status = eunit(mutant)
    refute status.success?, output
    assert_match mutant.property, output
  end

  # Compiles the application, with the mutant's file edited when there is one, and the
  # cases into a directory of its own, and runs the cases.
  def eunit(mutant)
    Dir.mktmpdir('erx-wm-test') do |work|
      replaced = mutant ? { "#{SOURCE_DIRECTORY}/#{mutant.file}" => edited(mutant) } : {}
      ErlangBuild.compile(work, applications: %w[erx_display], tests: TESTS.map { |name| "test/erlang/#{name}.erl" },
                          replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{TESTS.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end).",
                      chdir: work, stdin_data: '')
    end
  end

  def edited(mutant)
    path = File.join(ROOT, SOURCE_DIRECTORY, mutant.file)
    source = File.binread(path)
    raise "#{path} no longer holds #{mutant.text.inspect}" unless source.include?(mutant.text)

    source.sub(mutant.text, mutant.broken)
  end
end
