# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_domain_tests.erl, the EUnit cases of the domain service
# (docs/design-system.md, "System services"): erx_ident, erx_domain_core and
# erx_domain_srv over a stand-in for the domain library's NIF module, compiled
# with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies).
class ErxDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_domain/src')
  SOURCES = [*Dir[File.join(APPLICATION, '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_domain_fake_lib.erl'),
             File.join(ROOT, 'test/erlang/erx_domain_tests.erl')].freeze

  def test_domain_service_cases_pass_under_eunit
    Dir.mktmpdir('erx-domain-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_domain_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
