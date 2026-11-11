# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs the EUnit cases of the domain service (docs/design-system.md, "System
# services"), compiled with warnings as errors on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies): test/erlang/erx_domain_tests.erl
# for erx_ident, erx_domain_core and erx_domain_srv over a stand-in for the
# domain library's NIF module, and test/erlang/erx_domain_links_tests.erl,
# the exhaustive exploration of the connection protocol's core,
# test/erlang/erx_domain_mints_tests.erl, the exhaustive exploration of the
# core that mints facets configured domains serve,
# test/erlang/erx_domain_mints_srv_tests.erl for the service applying that core, and
# test/erlang/erx_facet_tests.erl for the facet behaviour, erx_facet, which the
# service mints facets of, and test/erlang/erx_devices_tests.erl for erx_devices,
# the catalogue presented unchanged, and test/erlang/erx_driver_ctl_tests.erl for
# erx_driver_ctl, the driver-control facet.
class ErxDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_domain/src')
  SOURCES = [*Dir[File.join(APPLICATION, '*.erl')].sort,
             File.join(ROOT, 'erlang/apps/erx/src/erx_facet.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_driver_ctl.erl'),
             File.join(ROOT, 'test/erlang/erx_driver_ctl_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_facet_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_domain_fake_lib.erl'),
             File.join(ROOT, 'test/erlang/erx_domain_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_domain_links_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_domain_mints_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_domain_mints_srv_tests.erl'),
             File.join(ROOT, 'test/erlang/erx_devices_tests.erl')].freeze

  def test_domain_service_cases_pass_under_eunit
    assert_eunit_passes('erx_domain_tests', deadline: 120)
  end

  def test_facet_behaviour_cases_pass_under_eunit
    assert_eunit_passes('erx_facet_tests', deadline: 60)
  end

  def test_connection_protocol_core_passes_under_eunit
    assert_eunit_passes('erx_domain_links_tests', deadline: 300)
  end

  def test_facet_mint_core_passes_under_eunit
    assert_eunit_passes('erx_domain_mints_tests', deadline: 120)
  end

  def test_domain_service_applies_the_mint_core_under_eunit
    assert_eunit_passes('erx_domain_mints_srv_tests', deadline: 60)
  end

  def test_driver_control_facet_passes_under_eunit
    assert_eunit_passes('erx_driver_ctl_tests', deadline: 60)
  end

  def test_device_catalogue_presentation_passes_under_eunit
    assert_eunit_passes('erx_devices_tests', deadline: 60)
  end

  private

  def assert_eunit_passes(mod, deadline:)
    Dir.mktmpdir('erx-domain-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', deadline.to_s, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval',
                                       "halt(case eunit:test(#{mod}, [verbose]) of ok -> 0; _ -> 1 end).",
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/[1-9][0-9]* tests passed/, output)
    end
  end
end
