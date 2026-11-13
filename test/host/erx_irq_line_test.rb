# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# erx_irq_line:owners/1 under EUnit on the stock emulator (test/erlang/erx_irq_line_tests.erl),
# and the design's seeded fault: one owner per record, so a driver's two records on one line
# give two owners. The owner process runs on the hosted runtime
# (test/integration/runtime_device_test.rb).
class ErxIrqLineTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_irq_line.erl')
  TESTS_SOURCE = File.join(ROOT, 'test/erlang/erx_irq_line_tests.erl')
  PER_RECORD = ['    first_of_each(Named, #{}, []).', '    [Owner || {_, Owner} <- Named].'].freeze

  def test_owners_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE), warnings_as_errors: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_one_owner_per_record_fails_its_cases
    source = File.binread(MODULE_SOURCE)
    assert_equal 1, source.scan(PER_RECORD.first).size
    output, status = eunit(source.sub(*PER_RECORD), warnings_as_errors: false)
    refute status.success?, output
    %w[every_set_of_drivers_gets_one_owner_per_shared_line_test
       a_drivers_two_records_on_one_line_give_one_owner_test].each do |name|
      assert_match(/#{name}\.\.\.(\[[^\]]*\] )?\*failed\*/, output, "#{name} did not catch the seed")
    end
  end

  private

  def eunit(module_text, warnings_as_errors:)
    Dir.mktmpdir('erx-irq-line-test') do |work|
      module_path = File.join(work, 'erx_irq_line.erl')
      File.binwrite(module_path, module_text)
      flags = warnings_as_errors ? ['-Werror'] : []
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, '-o', work, module_path, TESTS_SOURCE,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_irq_line_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
