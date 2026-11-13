# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_blk_image_tests.erl, the EUnit cases of the windows on the booted
# slot's EROFS images and an image window's refusal of writes, against erx_blk_image,
# erx_blk_window and the generated manifest reader compiled
# from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The
# manifests its cases read are the development manifest as the packer admits it, with the
# release image where the fixture puts it, in two extents, and with no window on it.
class ErxBlkImageTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the cases exercise, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_blk].freeze
  TESTS = %w[test/erlang/erx_blk_image_tests.erl].freeze
  TWO_EXTENTS = [{ 'slot_offset' => 128 << 20, 'length' => 4096 },
                 { 'slot_offset' => (128 << 20) + 8192, 'length' => 4096 }].freeze

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    # erx_blk_image places the windows the system domain holds; the development manifest
    # gives the release window to the storage domain, which does not place it, so the
    # cases start from the manifest with the system domain holding it.
    @source = ManifestContextFixture.domainless(File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt')))
    @platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
  end

  def test_image_window_cases_pass_under_eunit
    Dir.mktmpdir('erx-blk-image-test') do |work|
      manifests.each { |name, bytes| File.binwrite(File.join(work, "manifest-#{name}"), bytes) }
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_blk_image_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  def manifests
    no_window = @source.sub(/^window release\n(?:  .*\n)+/, '')
    refute_equal @source, no_window
    { 'good' => admit(@source), 'two-extents' => admit(@source, extents: TWO_EXTENTS), 'no-window' => admit(no_window) }
  end

  def admit(source, extents: nil)
    arguments = ManifestContextFixture.arguments(@codec).merge(platform: @platform, build_kind: 'development')
    arguments[:artifacts] = arguments[:artifacts].merge('release' => { 'kind' => 'erofs_image', 'extents' => extents }) if extents
    # The manifest keeps root's session template, so root's console session needs a
    # planner (property 17); the accepting one plans everything.
    Erx::Manifest.admit(source: source, codec: @codec, context: Erx::Manifest::Context.new(**arguments),
                        planner: ManifestContextFixture.accepting_planner).bytes
  end
end
