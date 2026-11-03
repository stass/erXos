# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/toolchain_provenance'

class ToolchainProvenanceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('erx-toolchain-provenance-')
    @installation = File.join(@root, 'installation')
    Dir.mkdir(@installation)
    File.binwrite(File.join(@installation, 'header.h'), 'header bytes')
    File.binwrite(File.join(@installation, 'LICENSE'), 'license bytes')
    @profile = File.join(@root, 'profile.json')
    @document = { 'version' => 1, 'label' => 'toolchain-1', 'license' => 'MIT',
                  'status' => 'permanent', 'evidence' => 'reviewed test fixture',
                  'files' => { 'header.h' => Digest::SHA256.hexdigest('header bytes') },
                  'notices' => { 'LICENSE' => Digest::SHA256.hexdigest('license bytes') } }
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def registry
    File.binwrite(@profile, JSON.generate(@document))
    Erx::ToolchainProvenance.registry(profile: @profile, installation: @installation)
  end

  def test_exact_files_and_public_labels
    records = registry
    assert_equal ['toolchain/toolchain-1/header.h'], records.map { |item| item.fetch('label') }
    assert_equal 'MIT', records.first.fetch('license')
    assert_equal Digest::SHA256.hexdigest('license bytes'), records.first.fetch('notices').first.fetch('sha256')
    assert records.frozen?
    assert records.first.frozen?
  end

  def test_changed_header_and_notice_are_refused
    File.binwrite(File.join(@installation, 'header.h'), 'changed')
    assert_raises(Erx::Error) { registry }
    File.binwrite(File.join(@installation, 'header.h'), 'header bytes')
    File.binwrite(File.join(@installation, 'LICENSE'), 'changed')
    assert_raises(Erx::Error) { registry }
  end

  def test_escape_and_non_file_are_refused
    outside = File.join(@root, 'outside.h')
    File.binwrite(outside, 'header bytes')
    File.unlink(File.join(@installation, 'header.h'))
    File.symlink(outside, File.join(@installation, 'header.h'))
    assert_raises(Erx::Error) { registry }
    @document['files'] = { '../outside.h' => Digest::SHA256.hexdigest('header bytes') }
    assert_raises(Erx::Error) { registry }
  end

  def test_malformed_attribution_is_typed
    [nil, [], 12].each do |license|
      @document['license'] = license
      assert_raises(Erx::Error) { registry }
    end
    @document['license'] = 'MIT'
    @document['extra'] = true
    assert_raises(Erx::Error) { registry }
  end
end
