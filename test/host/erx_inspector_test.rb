# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs the EUnit cases of the inspector on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): erx_kernel_records' pure core (test/erlang/erx_kernel_records_tests.erl),
# the process records, scopes and renderers (test/erlang/erx_inspector_tests.erl) and the kernel
# log facet (test/erlang/erx_log_facet_tests.erl), against
# the sources, the generated ones from build/gen. erx_object_info is compiled but its NIF is
# never loaded: the cases reach the kernel only through the pure core.
class ErxInspectorTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  ERX = File.join(ROOT, 'erlang/apps/erx')
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = [*%w[generated/erx_schema erx_text_tables]
               .map { |name| Erx::Generated.path("erlang/apps/erx/src/#{name}.erl", root: ROOT) },
             *%w[erx_text erx_object_info erx_kernel_records erx_process_records erx_inspector
                 erx_log_records erx_log_facet erx_runtime_records erx_facets erx erx_inspect_agent].map { |name| File.join(ERX, "src/#{name}.erl") },
             *%w[erx_render].map { |name| File.join(ROOT, "erlang/apps/erx_shell/src/#{name}.erl") },
             File.join(ROOT, 'test/erlang/erx_kernel_records_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_inspector_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_log_facet_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_inspect_agent_tests.erl')].freeze

  # Each fault replaces one passage of one source, and the case it names must fail.
  Fault = Data.define(:name, :file, :from, :to, :tests, :caught_by)
  AGENT = File.join(ERX, 'src/erx_inspect_agent.erl')
  FAULTS = [
    Fault.new(name: 'an agent that answers any origin', file: AGENT,
              from: 'handle({erx_origin, SystemId, {erx_inspect_ask, Alias, Query}}, Self, SystemId) when',
              to: 'handle({erx_origin, _Origin, {erx_inspect_ask, Alias, Query}}, Self, _SystemId) when',
              tests: 'erx_inspect_agent_tests', caught_by: 'answers_only_the_system_domain_test'),
    Fault.new(name: 'an agent that takes exactly [processes, Pid]', file: AGENT,
              from: 'owns([processes, {pid, Self, _Number, _Serial} | _], Self) -> true;',
              to: 'owns([processes, {pid, Self, _Number, _Serial}], Self) -> true;',
              tests: 'erx_inspect_agent_tests', caught_by: 'answers_paths_below_its_processes_test')
  ].freeze

  def test_kernel_record_cases_pass_under_eunit
    eunit('erx_kernel_records_tests')
  end

  def test_inspector_cases_pass_under_eunit
    eunit('erx_inspector_tests')
  end

  def test_log_facet_cases_pass_under_eunit
    eunit('erx_log_facet_tests')
  end

  def test_runtime_agent_cases_pass_under_eunit
    eunit('erx_inspect_agent_tests')
  end

  def test_the_cases_catch_each_seeded_fault
    FAULTS.each do |fault|
      source = File.read(fault.file)
      assert_includes source, fault.from, fault.name
      Dir.mktmpdir('erx-inspector-fault') do |faulted|
        copy = File.join(faulted, File.basename(fault.file))
        File.write(copy, source.sub(fault.from, fault.to))
        passed, text = eunit_run(fault.tests, SOURCES.map { |path| path == fault.file ? copy : path })
        refute passed, "#{fault.name} passed:\n#{text}"
        assert_match(/#{fault.caught_by}.*\*failed\*/m, text, fault.name)
      end
    end
  end

  private

  def eunit(suite)
    passed, output = eunit_run(suite, SOURCES)
    assert passed, output
    assert_match(/All \d+ tests passed/, output)
  end

  # Compiles Sources with warnings as errors and runs Suite's cases: whether they passed,
  # and the run's text.
  def eunit_run(suite, sources)
    Dir.mktmpdir('erx-inspector-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, *sources, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', "halt(case eunit:test(#{suite}, [verbose]) of ok -> 0; _ -> 1 end)",
                                       chdir: work, stdin_data: '')
      [status.success?, output]
    end
  end
end
