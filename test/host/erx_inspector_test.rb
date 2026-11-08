# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs the EUnit cases of the inspector on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): erx_kernel_records' pure core (test/erlang/erx_kernel_records_tests.erl)
# and the process records, scopes and renderers (test/erlang/erx_inspector_tests.erl), against
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
             *%w[erx_text erx_object_info erx_kernel_records erx_process_records
                 erx_inspector erx_runtime_records erx].map { |name| File.join(ERX, "src/#{name}.erl") },
             *%w[erx_render erx_shell_script].map { |name| File.join(ROOT, "erlang/apps/erx_shell/src/#{name}.erl") },
             File.join(ROOT, 'test/erlang/erx_kernel_records_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_inspector_tests.erl')].freeze

  def test_kernel_record_cases_pass_under_eunit
    eunit('erx_kernel_records_tests')
  end

  def test_inspector_cases_pass_under_eunit
    eunit('erx_inspector_tests')
  end

  private

  def eunit(suite)
    Dir.mktmpdir('erx-inspector-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE,
                                       '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', "halt(case eunit:test(#{suite}, [verbose]) of ok -> 0; _ -> 1 end)",
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
