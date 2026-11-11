# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

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
# the catalogue presented unchanged, test/erlang/erx_driver_ctl_tests.erl for
# erx_driver_ctl, the driver-control facet, and erx_blk_sup behind it, and
# test/erlang/erx_devfs_tests.erl for /dev, erx_devfs and erx_devfs_core, with the
# erx_fs behaviour and the schema's and text's modules they call. Each fault of
# FAULTS replaces one passage of one of these sources, and the case it names must fail.
class ErxDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # erx_domain_srv includes the generated erx_abi.hrl, in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_domain/src')
  # Compiled before the rest: erx_devfs names it as its behaviour.
  BEHAVIOUR = File.join(ROOT, 'erlang/apps/erx_files/src/erx_fs.erl')
  SOURCES = [*Dir[File.join(APPLICATION, '*.erl')].sort,
             Erx::Generated.path('erlang/apps/erx/src/generated/erx_schema.erl', root: ROOT),
             Erx::Generated.path('erlang/apps/erx/src/erx_text_tables.erl', root: ROOT),
             File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(ROOT, 'test/erlang/erx_devfs_tests.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_facet.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_driver_ctl.erl'),
             File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_sup.erl'),
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

  def test_dev_tree_passes_under_eunit
    assert_eunit_passes('erx_devfs_tests', deadline: 60)
  end

  # Each fault replaces one passage of one source of the service, and the case it names,
  # of the EUnit module tests, must fail.
  Fault = Data.define(:name, :file, :from, :to, :tests, :caught_by)
  FAULTS = [
    # The read-only tree's own refusal of ctl, the seeded fault of P5b: without it the
    # tree walks to ctl, so a session holding only the read-only tree could reset a driver.
    Fault.new(name: 'a read-only tree that accepts ctl', file: File.join(APPLICATION, 'erx_devfs.erl'),
              from: %q{walk({device, Index}, <<"ctl">>, #{rights := rw}) ->},
              to: %q{walk({device, Index}, <<"ctl">>, _Fs) ->},
              tests: 'erx_devfs_tests', caught_by: 'the_read_only_tree_has_no_ctl_test'),
    # The inspect facet's scope (docs/design-live.md, "The inspect service"): a development
    # build that gives every principal's session the whole machine.
    Fault.new(name: 'scope all for every principal of a development build',
              file: File.join(APPLICATION, 'erx_domain_core.erl'),
              from: 'Development andalso lists:member(Principal, Roots)',
              to: 'Development andalso is_list(Roots)',
              tests: 'erx_domain_tests', caught_by: 'inspect_scope_test')
  ].freeze

  def test_the_cases_catch_each_seeded_fault
    FAULTS.each do |fault|
      source = File.read(fault.file)
      assert_includes source, fault.from, fault.name
      Dir.mktmpdir('erx-domain-fault') do |faulted|
        copy = File.join(faulted, File.basename(fault.file))
        File.write(copy, source.sub(fault.from, fault.to))
        sources = SOURCES.map { |path| path == fault.file ? copy : path }
        output = eunit_output(fault.tests, deadline: 120, sources: sources)
        refute output.fetch(:passed), "#{fault.name} passed:\n#{output.fetch(:text)}"
        assert_match(/#{fault.caught_by}.*\*failed\*/m, output.fetch(:text), fault.name)
      end
    end
  end

  private

  def assert_eunit_passes(mod, deadline:)
    output = eunit_output(mod, deadline: deadline, sources: SOURCES)
    assert output.fetch(:passed), output.fetch(:text)
    assert_match(/[1-9][0-9]* tests passed/, output.fetch(:text))
  end

  # Compiles Sources with warnings as errors and runs Mod's cases: whether they passed,
  # and the run's text.
  def eunit_output(mod, deadline:, sources:)
    Dir.mktmpdir('erx-domain-test') do |work|
      [[BEHAVIOUR], sources].each do |batch|
        output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work,
                                         *batch, stdin_data: '')
        assert status.success?, output
      end

      output, status = Open3.capture2e('gtimeout', '-k', '10', deadline.to_s, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval',
                                       "halt(case eunit:test(#{mod}, [verbose]) of ok -> 0; _ -> 1 end).",
                                       chdir: work, stdin_data: '')
      { passed: status.success?, text: output }
    end
  end
end
