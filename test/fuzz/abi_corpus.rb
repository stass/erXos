#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/abi_manifest_fixture'

begin
  abort('usage: abi_corpus.rb DIRECTORY') unless ARGV.size == 1
  directory = File.expand_path(ARGV.first)
  FileUtils.mkdir_p(directory)
  {
    'manifest' => AbiManifestFixture.valid,
    'partition' => AbiManifestFixture.unit_partition,
    'overlap' => AbiManifestFixture.unit_partition(overlap: true),
    'orphan' => AbiManifestFixture.unit_partition(orphan: true),
    'parameter' => AbiManifestFixture.facet_parameter,
    'session' => AbiManifestFixture.session_template,
    'empty' => ''.b
  }.each do |name, bytes|
    File.open(File.join(directory, name), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.binmode
      file.write(bytes)
    end
  end
rescue Erx::Error, SystemCallError => error
  Erx::Terminal.puts("cannot create ABI corpus: #{error.message}")
  exit 1
end
