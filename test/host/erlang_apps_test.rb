# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/erlang_apps'

# Which files make up an erXos application: its modules under erlang/apps/<app>/src
# and the generated ones at the same paths under build/gen, which the build compiles
# and the release's receipts name.
class ErlangAppsTest < Minitest::Test
  ErlangApps = Erx::ErlangApps

  def setup
    @root = File.realpath(Dir.mktmpdir('erx-erlang-apps-'))
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def write(path, text = File.basename(path))
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def test_an_application_compiles_its_own_and_its_generated_modules
    write('erlang/apps/erx/src/erx_text.erl')
    write('build/gen/erlang/apps/erx/src/erx_text_tables.erl')
    write('build/gen/erlang/apps/erx/src/generated/erx_manifest.erl')
    assert_equal %w[build/gen/erlang/apps/erx/src/erx_text_tables.erl erlang/apps/erx/src/erx_text.erl
                    build/gen/erlang/apps/erx/src/generated/erx_manifest.erl].sort,
                 ErlangApps.modules(root: @root, application: 'erx').sort
  end

  def test_the_receipts_sources_name_generated_modules_and_the_resource_file
    write('erlang/apps/erx/src/erx_text.erl')
    write('build/gen/erlang/apps/erx/src/generated/erx_manifest.erl')
    sources = ErlangApps.sources(root: @root).select { |path| path.include?('/apps/erx/') }
    assert_equal %w[build/gen/erlang/apps/erx/src/generated/erx_manifest.erl erlang/apps/erx/src/erx.app.src
                    erlang/apps/erx/src/erx_text.erl].map { |path| File.join(@root, path) }, sources.sort
  end
end
