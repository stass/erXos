# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rbconfig'
require_relative '../../tools/lib/erx/oracle'

class OracleTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('erx-oracle-')
    FileUtils.copy_file(File.expand_path('../../deps.lock', __dir__), File.join(@root, 'deps.lock'))
    @oracle = Erx::Oracle.new(root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_unsupported_flavour_is_refused_before_build
    assert_raises(Erx::Error) { @oracle.build(flavours: ['unknown']) }
  end

  def test_bad_job_count_is_refused_before_build
    assert_raises(Erx::Error) { @oracle.build(jobs: 0) }
  end

  def test_oversized_native_receipt_is_refused_before_loading_json
    directory = File.join(@root, 'build/oracle/emu')
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, 'build.json'), 'x' * (1024 * 1024 + 1))
    parsed = false
    Erx::JsonInput.stub(:parse, lambda { |*_, **_keywords| parsed = true; raise Erx::Error, 'fixture parser refusal' }) do
      assert_raises(Erx::Error) { @oracle.verify('emu') }
    end
    refute parsed, 'oversized receipt reached the JSON parser after an unbounded file read'
  end

  def test_matching_marker_does_not_admit_mutated_stock_sources
    directory = File.join(@root, 'build/oracle/emu')
    FileUtils.mkdir_p(File.join(directory, 'source'))
    File.write(File.join(directory, 'source/configure'), 'modified source')
    plan = { 'id' => 'fixture' }
    File.write(File.join(directory, 'source.json'), JSON.generate(plan))
    assert_raises(Erx::Error) do
      @oracle.send(:prepare_source, 'emu', source: {}, archive: 'unused', plan: plan)
    end
  end

  def test_symlink_source_is_refused_even_with_matching_marker
    directory = File.join(@root, 'build/oracle/emu')
    outside = File.join(@root, 'outside')
    FileUtils.mkdir_p(directory)
    Dir.mkdir(outside)
    File.symlink(outside, File.join(directory, 'source'))
    plan = { 'id' => 'fixture' }
    File.write(File.join(directory, 'source.json'), JSON.generate(plan))
    assert_raises(Erx::Error) do
      @oracle.send(:prepare_source, 'emu', source: {}, archive: 'unused', plan: plan)
    end
  end

  def install_launcher(body)
    path = @oracle.erl_path('emu')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o755, path)
  end

  def ready_receipt
    pin = JSON.parse(File.read(File.join(@root, 'deps.lock'))).fetch('sources').find { |source| source.fetch('id') == 'otp' }
    report = { 'state' => 'ready', 'version' => '29.1.2', 'flavour' => 'emu',
               'source_sha256' => pin.fetch('sha256') }
    File.write(File.join(@root, 'build/oracle/emu/build.json'), JSON.generate(report))
  end

  def test_installed_primary_emulator_does_not_require_a_flavour_filename
    install_launcher("abort 'only beam.smp is installed' if ARGV.include?('-emu_flavor'); puts 'ERX_ORACLE 29.1.2 emu'")
    ready_receipt
    assert_equal 'succeeded', @oracle.verify('emu').fetch('state')
  end

  def test_launcher_cannot_redirect_through_inherited_erlang_root
    previous = ENV['ERL_ROOTDIR']
    ENV['ERL_ROOTDIR'] = '/unexpected/root'
    install_launcher("abort 'foreign root' if ENV['ERL_ROOTDIR']; puts 'ERX_ORACLE 29.1.2 emu'")
    ready_receipt
    assert_equal 'succeeded', @oracle.verify('emu').fetch('state')
  ensure
    ENV['ERL_ROOTDIR'] = previous
  end

  def test_partial_install_cannot_be_accepted_as_a_ready_oracle
    install_launcher("puts 'ERX_ORACLE 29.1.2 emu'")
    assert_raises(Erx::Error) { @oracle.verify('emu') }
  end

  def test_modified_source_cannot_be_executed_after_ready_install_verifies
    install_launcher("puts 'ERX_ORACLE 29.1.2 emu'")
    ready_receipt
    source = @oracle.source_path('emu')
    FileUtils.mkdir_p(File.join(source, 'erts/emulator'))
    File.write(File.join(source, 'Makefile'), 'modified build input')
    erlc = File.join(File.dirname(@oracle.erl_path('emu')), 'erlc')
    File.write(erlc, "#!#{RbConfig.ruby}\nexit 0\n")
    File.chmod(0o755, erlc)
    marker = File.join(@root, 'modified-source-executed')
    make = File.join(@root, 'fake-make')
    File.write(make, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'executed')\n")
    File.chmod(0o755, make)
    receipt = File.join(@root, 'build/oracle/emu/build.json')
    report = JSON.parse(File.read(receipt))
    report['make'] = { 'path' => make }
    report['build_environment'] = {}
    File.write(receipt, JSON.generate(report))
    assert_raises(Erx::Error) { @oracle.run('emulator', deadline: 10) }
    refute File.exist?(marker), 'suite make ran from modified source after a stock install probe'
  end

  def test_native_full_suite_execution_is_unsupported
    error = assert_raises(Erx::Error) { @oracle.run('emulator') }
    assert_match(/Linux container/, error.message)
    refute File.exist?(File.join(@root, 'build/oracle/emu'))
  end
end
