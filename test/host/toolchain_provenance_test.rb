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
    File.binwrite(File.join(@installation, 'header.h'), "/* SPDX-License-Identifier: MIT */\nint x;\n")
    File.binwrite(File.join(@installation, 'LICENSE'), 'license bytes')
    @profile = File.join(@root, 'profile.json')
    @document = { 'version' => 1, 'label' => 'toolchain-1', 'license' => 'MIT',
                  'status' => 'permanent', 'evidence' => 'reviewed test fixture',
                  'files' => ['header.h'], 'notices' => ['LICENSE'] }
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

  def test_escape_and_non_file_are_refused
    outside = File.join(@root, 'outside.h')
    File.binwrite(outside, 'header bytes')
    File.unlink(File.join(@installation, 'header.h'))
    File.symlink(outside, File.join(@installation, 'header.h'))
    assert_raises(Erx::Error) { registry }
    @document['files'] = ['../outside.h']
    assert_raises(Erx::Error) { registry }
  end

  # A header is admitted by the license it declares itself, from whatever
  # release is installed, and its record carries the bytes it has.
  def test_header_is_admitted_by_its_own_license_line
    bytes = "/*===---- header.h ---===\n * SPDX-License-Identifier: MIT\n */\nint x;\n"
    File.binwrite(File.join(@installation, 'header.h'), bytes)
    records = registry
    assert_equal Digest::SHA256.hexdigest(bytes), records.first.fetch('sha256')
    assert_equal 'MIT', records.first.fetch('license')
  end

  def test_header_with_another_or_no_license_line_is_refused
    ["/* SPDX-License-Identifier: Apache-2.0 */\n", "/* no license line */\n",
     "/* SPDX-License-Identifier: MIT OR GPL-2.0-only */\n",
     "#{"/* padding */\n" * 400}/* SPDX-License-Identifier: MIT */\n",
     # The window ends right after "MIT": a cut-off line declares nothing.
     "/*#{"x" * (4096 - 3 - 31)}\n/* SPDX-License-Identifier: MIT OR GPL-2.0-only */\n"].each do |bytes|
      File.binwrite(File.join(@installation, 'header.h'), bytes)
      error = assert_raises(Erx::Error) { registry }
      assert_equal 'toolchain provenance: header.h does not declare MIT', error.message
    end
  end

  # Files may live below a directory of their own (clang's resource directory)
  # while notices stay at the installation's root.
  def test_files_resolve_under_their_own_root
    resource = File.join(@installation, 'lib/clang/24')
    FileUtils.mkdir_p(File.join(resource, 'include'))
    File.binwrite(File.join(resource, 'include/stddef.h'), "/* SPDX-License-Identifier: MIT */\n")
    @document['files'] = ['include/stddef.h']
    File.binwrite(@profile, JSON.generate(@document))
    records = Erx::ToolchainProvenance.registry(profile: @profile, installation: @installation, files_root: resource)
    assert_equal ['toolchain/toolchain-1/include/stddef.h'], records.map { |item| item.fetch('label') }
    assert_equal File.realpath(File.join(@installation, 'LICENSE')), records.first.fetch('notices').first.fetch('path')
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

  # LLVM's notice comes from LLVM's own install tree, or from a FreeBSD
  # port's license directory, where it is named LLVM2; with neither, the
  # profile's notice is missing and the registry refuses it.
  def test_llvm_notice_comes_from_the_install_tree_or_the_freebsd_package
    tree = File.join(@root, 'tree')
    FileUtils.mkdir_p(File.join(tree, 'config/provenance'))
    File.binwrite(File.join(tree, Erx::ToolchainProvenance::LLVM_PROFILE),
                  JSON.generate(@document.merge('files' => ['include/header.h'], 'notices' => ['LICENSE.TXT'])))
    port = File.join(@root, 'local/llvm23')
    resource = File.join(port, 'lib/clang/23')
    FileUtils.mkdir_p(File.join(resource, 'include'))
    File.binwrite(File.join(resource, 'include/header.h'), "/* SPDX-License-Identifier: MIT */\n")
    llvm = -> { Erx::ToolchainProvenance.llvm(root: tree, resource_dir: resource).first.fetch('notices').first }
    assert_raises(Erx::Error) { llvm.call }

    licenses = File.join(@root, 'local/share/licenses/llvm23-23.1.3')
    FileUtils.mkdir_p(licenses)
    File.binwrite(File.join(licenses, 'LLVM2'), 'port notice')
    assert_equal Digest::SHA256.hexdigest('port notice'), llvm.call.fetch('sha256')

    File.binwrite(File.join(port, 'LICENSE.TXT'), 'tree notice')
    assert_equal Digest::SHA256.hexdigest('tree notice'), llvm.call.fetch('sha256')
  end
end
