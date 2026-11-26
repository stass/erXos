# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/fuzz/package_seeds'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pkg_tests.erl, the EUnit cases of the package process at boot
# (docs/design-packaging.md, "Boot and recovery"): the file check, the recovery's plan, the
# path table and the package process under its supervisor, over a simulated medium, with
# the real admission and with registration and publication stubbed (test/erlang/erx_pkg_stubs).
# They compile from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC).
# The package files are written here through the ABI codec (Erx::PackageSeeds): three
# well-formed packages, dashboard, clock and other, each sealed by a fresh Ed25519 key
# whose public half is key.bin. erx_bytes is the host stand-in (test/erlang/host_bytes),
# whose Ed25519 check is stock's crypto.
class ErxPkgTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = (%w[erlang/apps/erx/src/erx_pkg_header.erl otp/erts/preloaded/src/erx_verity_tree.erl
                build/gen/erlang/apps/erx/src/generated/erx_pkg_reader.erl
                erlang/apps/erx_domain/src/erx_app_admit.erl erlang/apps/erx_domain/src/erx_domain_core.erl
                erlang/apps/erx_domain/src/erx_ident.erl erlang/apps/erx_files/src/erx_fs_version.erl
                erlang/apps/erx_starter/src/erx_pkg_plan.erl erlang/apps/erx_starter/src/erx_pkg_io.erl
                erlang/apps/erx_starter/src/erx_pkg.erl erlang/apps/erx_starter/src/erx_pkg_sup.erl
                test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_pkg_tests.erl] +
             Dir.glob('test/erlang/erx_pkg_stubs/*.erl', base: ROOT)).map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  # The image's packages read through the real erx_pkg_medium over a stand-in system grant
  # (test/erlang/erx_pkg_system_tests.erl): the start service's application compiled whole
  # (ErlangBuild), the registration, publication and namespace stubs over its modules, and
  # the 9P client with a stand-in for prim_file's fids, as test/host/erx_ns_test.rb does.
  SYSTEM_APPLICATIONS = %w[erx_starter].freeze
  SYSTEM_TESTS = [*%w[test/erlang/host_bytes/erx_bytes.erl
                      test/erlang/erx_fs_test_tree.erl test/erlang/stand_in/erx_dist.erl],
                  *%w[erx_domain erx_principal erx_starter].map { |stub| "test/erlang/erx_pkg_stubs/#{stub}.erl" },
                  'test/erlang/erx_pkg_system_tests.erl'].freeze
  FILE_REMOTE = 'otp/erts/preloaded/src/erx_file_remote.erl'
  FID = "fid() ->\n    prim_file:erx_fid().\n"
  STAND_IN_FID = "fid() ->\n    erlang:unique_integer([positive]).\n"

  Seeds = Erx::PackageSeeds

  def test_package_process_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_image_packages_read_through_the_system_grant_once_the_namespace_settles
    Dir.mktmpdir('erx-pkg-system-test') do |work|
      ErlangBuild.compile(work, applications: SYSTEM_APPLICATIONS, tests: SYSTEM_TESTS,
                                replaced: { FILE_REMOTE => file_remote }, includes: %w[otp/lib/kernel/include])
      write_packages(work)
      output, status = Open3.capture2e({ 'ERX_PKG_FILES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                                       '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_pkg_system_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/ \d+ tests passed/, output)
    end
  end

  private

  def file_remote
    text = File.read(File.join(ROOT, FILE_REMOTE))
    raise 'the client has no fid/0 to stand in for' unless text.include?(FID)

    text.sub(FID) { STAND_IN_FID }
  end

  # key.bin and the five packages, each sealed by a fresh Ed25519 key, each declaring the
  # GATT services beside its name.
  def write_packages(work)
    signer = Erx::AppPackage::Signer.new(OpenSSL::PKey.generate_key('ED25519'))
    File.binwrite(File.join(work, 'key.bin'), signer.public_key)
    { 'dashboard' => %w[nus], 'clock' => [], 'other' => %w[hrm], 'relay' => %w[nus], 'pulse' => %w[hrm] }
      .each do |name, gatt|
      File.binwrite(File.join(work, "#{name}.bin"), package(name, gatt: gatt, signer: signer).prefix)
    end
  end

  def package(name, gatt:, signer:)
    Seeds.sample(name, declaration: Seeds::ERLANG.with(name: name, gatt: gatt), image_blocks: 3, tree_blocks: 1,
                       signer: signer)
  end

  def eunit
    Dir.mktmpdir('erx-pkg-test') do |work|
      write_packages(work)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work,
                                       '-o', work, *SOURCES, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e({ 'ERX_PKG_FILES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work, '-eval', 'eunit:test(erx_pkg_tests, [verbose]), halt().',
                      stdin_data: '')
    end
  end
end
