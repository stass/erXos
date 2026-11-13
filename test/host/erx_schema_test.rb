# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of erx_schema on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): test/erlang/erx_schema_tests.erl against the checked-in module
# generated from abi/inspection.txt, and test/erlang/erx_schema_forms_tests.erl against
# the module generated from test/fixtures/inspection_forms, which uses every form.
class ErxSchemaTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application holding erx_schema, compiled whole (ErlangBuild), and the generated
  # erx_schema in build/gen, which the forms suite replaces with its own.
  Erx::Generated.ensure(root: ROOT)
  APPLICATIONS = %w[erx].freeze
  SCHEMA = File.join(Erx::Generated::OUTPUT, Erx::ABI::InspectionEmitter::ERLANG_PATH)
  FORMS = File.join(ROOT, 'test/fixtures/inspection_forms')

  def test_checked_in_schema_cases_pass_under_eunit
    eunit('erx_schema_tests', File.binread(File.join(ROOT, SCHEMA)))
  end

  def test_every_form_passes_under_eunit
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: FORMS, architecture: nil))
    eunit('erx_schema_forms_tests', Erx::ABI::InspectionEmitter.erlang(schema.inspection, schema))
  end

  private

  def eunit(suite, module_text)
    Dir.mktmpdir('erx-schema-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: ["test/erlang/#{suite}.erl"],
                          replaced: { SCHEMA => module_text })
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', "halt(case eunit:test(#{suite}, [verbose]) of ok -> 0; _ -> 1 end)",
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
