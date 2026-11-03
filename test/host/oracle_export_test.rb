# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'socket'
require_relative '../../tools/lib/erx/oracle_export'

class OracleExportTest < Minitest::Test
  class FailingOutput
    def write(_bytes) = raise IOError, 'fixture write failure'
  end

  FailingFiles = Struct.new(:target) do
    def open(path, *arguments)
      File.open(path, *arguments) do |output|
        yield(path == target ? FailingOutput.new : output)
      end
    end
  end

  class CountingDirectories
    attr_reader :visited

    def initialize
      @visited = 0
    end

    def each_child(path)
      Dir.each_child(path) do |name|
        @visited += 1
        yield name
      end
    end
  end

  CT_ROOT = 'source/lib/kernel/make_test_dir/ct_logs'.freeze

  def setup
    # Native socket fixtures also live below Common Test's nested log paths.
    @directory = File.realpath(Dir.mktmpdir('erx-', '/tmp'))
    @source = File.join(@directory, 'source')
    @destination = File.join(@directory, 'artifacts')
    Dir.mkdir(@source, 0o700)
    Dir.mkdir(@destination, 0o700)
    @sockets = []
  end

  def teardown
    @sockets.each(&:close)
    FileUtils.remove_entry(@directory)
  end

  def write(path, bytes = 'evidence')
    target = File.join(@source, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.open(target, 'wb', 0o600) { |file| file.write(bytes) }
    target
  end

  def run_evidence
    write('result.json', '{"state":"completed"}')
    write('events.jsonl', "{\"event\":\"test_done\"}\n")
    write(CT_ROOT + '/ct_run/report/junit_report.xml', '<testsuites/>')
    write(CT_ROOT + '/ct_run/report/case.html', 'case details')
    write('logs/runner.log', 'runner evidence')
  end

  def export(operation: 'run', suite: 'kernel', changes: {}, **collaborators)
    limits = Erx::OracleExport::DEFAULT_LIMITS.merge(changes)
    Erx::OracleExport.call(source: @source, destination: @destination,
                          operation: operation, suite: suite, limits: limits, **collaborators)
  end

  def verify(changes: {})
    Erx::OracleExport.verify(destination: @destination,
                            limits: Erx::OracleExport::DEFAULT_LIMITS.merge(changes))
  end

  def read_inventory
    JSON.parse(File.binread(File.join(@destination, 'export.json')))
  end

  def replace_inventory(value)
    File.write(File.join(@destination, 'export.json'), JSON.generate(value))
  end

  def test_complete_run_copies_only_closed_reporting_roots
    run_evidence
    write('install/bin/erl', 'never copied')
    write('source/other.log', 'never copied')
    result = export
    assert_equal 'complete', result.fetch('state')
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert_equal 5, result.fetch('files').size
    refute File.exist?(File.join(@destination, 'install'))
    assert_equal result, verify
    result.fetch('files').each do |record|
      target = File.join(@destination, record.fetch('path'))
      assert_equal 0o600, File.stat(target).mode & 0o777
      assert_equal Digest::SHA256.file(target).hexdigest, record.fetch('sha256')
    end
    assert result.frozen?
    assert result.fetch('files').all?(&:frozen?)
  end

  def test_probe_requires_only_result_and_keeps_optional_status_separate
    write('result.json', '{}')
    result = export(operation: 'probe', suite: nil)
    assert_equal 'partial', result.fetch('state')
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert_equal ['result.json'], result.fetch('files').map { |file| file.fetch('path') }
    assert_equal result, verify
  end

  def test_xml_is_optional_when_controller_events_are_exported
    write('result.json', '{}')
    write('events.jsonl', '')
    result = export
    assert_equal 'complete', result.fetch('mandatory_evidence')
    refute result.fetch('files').any? { |file| file.fetch('path').end_with?('junit_report.xml') }
    assert_equal result, verify
  end

  def test_private_fixture_forms_are_pruned_before_links_and_special_files
    run_evidence
    %w[log_private log_private.1 log_private.cfg.2].each do |name|
      path = CT_ROOT + '/ct_run/report/' + name
      write(path + '/unneeded', 'private data')
      File.symlink('/outside/not-evidence', File.join(@source, path, 'link'))
      Dir.chdir(File.join(@source, path)) { @sockets << UNIXServer.new('socket') }
    end
    result = export
    assert_equal 'complete', result.fetch('state')
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert_equal 3, result.fetch('omissions').count { |issue| issue.fetch('reason') == 'private_fixture' }
    refute result.fetch('files').any? { |file| file.fetch('path').include?('log_private') }
    assert_equal result, verify
  end

  def test_ancillary_symlinks_and_sockets_do_not_change_case_evidence
    run_evidence
    File.symlink('/outside/private', File.join(@source, CT_ROOT, 'outside-link'))
    Dir.chdir(File.join(@source, CT_ROOT)) { @sockets << UNIXServer.new('socket') }
    result = export
    assert_equal 'partial', result.fetch('state')
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert_equal %w[excluded_special excluded_symlink], result.fetch('omissions').map { |issue| issue.fetch('reason') }.sort
    assert_equal result, verify
  end

  def test_selected_root_ancestors_are_never_followed
    write('result.json', '{}')
    write('events.jsonl', '')
    outside = File.join(@directory, 'outside')
    FileUtils.mkdir_p(File.join(outside, 'kernel/make_test_dir/ct_logs'))
    File.write(File.join(outside, 'kernel/make_test_dir/ct_logs/junit_report.xml'), 'outside secret')
    FileUtils.mkdir_p(File.join(@source, 'source'))
    File.symlink(outside, File.join(@source, 'source/lib'))
    result = export
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert_equal 'partial', result.fetch('state')
    refute result.fetch('files').any? { |file| file.fetch('path').start_with?('source/') }
    assert_equal result, verify
  end

  def test_hard_links_are_charged_and_copied_as_independent_files
    write('result.json', '{}')
    first = write('logs/first', 'same bytes')
    File.link(first, File.join(@source, 'logs/second'))
    result = export(operation: 'build', suite: nil)
    records = result.fetch('files').select { |file| file.fetch('path').start_with?('logs/') }
    assert_equal 2, records.size
    assert_equal 20, records.sum { |file| file.fetch('size') }
    assert_equal 2, records.map { |file| File.stat(File.join(@destination, file.fetch('path'))).ino }.uniq.size
    assert_equal result, verify
  end

  def test_per_file_and_total_byte_bounds_leave_mandatory_evidence_partial
    run_evidence
    result = export(changes: { 'file_bytes' => 4 })
    assert_equal 'partial', result.fetch('mandatory_evidence')
    assert result.fetch('omissions').any? { |issue| issue.fetch('reason') == 'file_bytes_limit' }
    assert_equal result, verify(changes: { 'file_bytes' => 4 })
  end

  def test_total_file_and_entry_limits_are_explicit
    run_evidence
    result = export(changes: { 'total_bytes' => 4, 'files' => 1, 'entries' => 16 })
    assert_equal 'partial', result.fetch('mandatory_evidence')
    assert result.fetch('omissions').any? { |issue| %w[total_bytes_limit file_limit entry_limit].include?(issue.fetch('reason')) }
    assert_equal result, verify(changes: { 'total_bytes' => 4, 'files' => 1, 'entries' => 16 })
  end

  def test_depth_and_path_limits_are_checked_before_copying
    run_evidence
    result = export(changes: { 'depth' => 2, 'path_bytes' => 12 })
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert_equal 'partial', result.fetch('state')
    assert result.fetch('omissions').any? { |issue| %w[depth_limit path_limit].include?(issue.fetch('reason')) }
    assert_equal result, verify(changes: { 'depth' => 2, 'path_bytes' => 12 })
  end

  def test_inventory_bound_publishes_bounded_partial_status
    write('result.json', '{}')
    result = export(operation: 'probe', suite: nil, changes: { 'inventory_bytes' => 4096 })
    assert_equal 'partial', result.fetch('state')
    assert_equal 'partial', result.fetch('mandatory_evidence')
    assert_operator File.size(File.join(@destination, 'export.json')), :<=, 4096
    assert_equal result, verify(changes: { 'inventory_bytes' => 4096 })
  end

  def test_copy_failure_keeps_prior_evidence_and_no_empty_unlisted_directories
    skip 'permission-denial fixture requires an unprivileged user' if Process.uid.zero?
    run_evidence
    unreadable = write(CT_ROOT + '/attachment/unreadable', 'not readable')
    File.chmod(0, unreadable)
    result = export
    assert_equal 'complete', result.fetch('mandatory_evidence')
    assert result.fetch('omissions').any? { |issue| issue.fetch('reason') == 'copy_failed' }
    assert_equal result, verify
  ensure
    File.chmod(0o600, unreadable) if unreadable && File.exist?(unreadable)
  end

  def test_existing_stage_is_never_overwritten
    write('result.json', '{}')
    target = File.join(@destination, 'keep')
    File.write(target, 'operator data')
    assert_raises(Erx::Error) { export(operation: 'probe', suite: nil) }
    assert_equal 'operator data', File.read(target)
  end

  def test_partial_write_failure_removes_new_file_and_empty_parents
    run_evidence
    path = CT_ROOT + '/attachment/broken'
    write(path, 'ordinary source bytes')
    target = File.join(@destination, path)
    result = export(open_destination: FailingFiles.new(target).method(:open))
    assert result.fetch('omissions').any? { |issue| issue.fetch('path') == path && issue.fetch('reason') == 'copy_failed' }, result.inspect
    refute File.exist?(target)
    refute File.exist?(File.dirname(target))
    assert_equal result, verify
  end

  def test_host_rejects_extra_entries_modified_bytes_and_unsafe_modes
    run_evidence
    export
    extra = File.join(@destination, 'extra')
    File.write(extra, 'unlisted')
    assert_raises(Erx::Error) { verify }
    File.unlink(extra)
    target = File.join(@destination, 'result.json')
    before = File.binread(target)
    File.binwrite(target, 'x' * before.bytesize)
    assert_raises(Erx::Error) { verify }
    File.binwrite(target, before)
    File.chmod(0o644, target)
    assert_raises(Erx::Error) { verify }
  end

  def test_host_rejects_duplicate_json_keys_and_traversal_paths
    run_evidence
    export
    original = File.binread(File.join(@destination, 'export.json'))
    File.write(File.join(@destination, 'export.json'), '{"version":1,"version":1}')
    assert_raises(Erx::Error) { verify }
    File.binwrite(File.join(@destination, 'export.json'), original)
    inventory = read_inventory
    inventory.fetch('files').first['path'] = '../outside'
    replace_inventory(inventory)
    assert_raises(Erx::Error) { verify }
  end

  def test_inventory_file_cannot_also_name_an_ancestor_directory
    run_evidence
    export
    inventory = read_inventory
    inventory.fetch('files') << { 'path' => CT_ROOT + '/ct_run', 'type' => 'file',
                                  'size' => 0, 'sha256' => '0' * 64, 'required' => false }
    inventory.fetch('files').sort_by! { |file| file.fetch('path').b }
    replace_inventory(inventory)
    assert_raises(Erx::Error) { verify }
  end

  def test_required_junit_record_cannot_be_a_directory
    run_evidence
    export
    inventory = read_inventory
    path = inventory.fetch('files').find { |file| file.fetch('path').end_with?('/junit_report.xml') }.fetch('path')
    target = File.join(@destination, path)
    File.unlink(target)
    Dir.mkdir(target, 0o700)
    File.open(File.join(target, 'child'), 'wb', 0o600) { |file| file.write('child') }
    inventory.fetch('files') << { 'path' => path + '/child', 'type' => 'file', 'size' => 5,
                                  'sha256' => Digest::SHA256.hexdigest('child'), 'required' => false }
    inventory.fetch('files').sort_by! { |file| file.fetch('path').b }
    replace_inventory(inventory)
    assert_raises(Erx::Error) { verify }
  end

  def test_canonical_ancestor_alias_is_rejected_before_filesystem_walk
    run_evidence
    export
    inventory = read_inventory
    sample = inventory.fetch('files').find { |file| file.fetch('path').start_with?('logs/') }
    inventory['files'] = inventory.fetch('files').reject { |file| file.fetch('path').start_with?('logs/') } +
                         %w[logs/A/one logs/a/two].map { |path| sample.merge('path' => path) }
    inventory.fetch('files').sort_by! { |file| file.fetch('path').b }
    replace_inventory(inventory)
    error = assert_raises(Erx::Error) { verify }
    assert_includes error.message, 'namespace pathname collision'
  end

  def test_case_and_unicode_normalization_collisions_are_rejected
    run_evidence
    export
    original = read_inventory
    [['logs/A', 'logs/a'], ["logs/caf\u00e9", "logs/cafe\u0301"]].each do |paths|
      inventory = Marshal.load(Marshal.dump(original))
      sample = inventory.fetch('files').find { |file| file.fetch('path').start_with?('logs/') }
      inventory['files'] = inventory.fetch('files').reject { |file| file.fetch('path').start_with?('logs/') } +
                           paths.map { |path| sample.merge('path' => path) }
      inventory['files'].sort_by! { |file| file.fetch('path').b }
      replace_inventory(inventory)
      assert_raises(Erx::Error) { verify }
    end
  end

  def test_unsupported_selection_and_unbounded_limits_fail_before_effects
    assert_raises(Erx::Error) { export(operation: 'other') }
    assert_raises(Erx::Error) { export(suite: '../other') }
    assert_raises(Erx::Error) { export(changes: { 'entries' => 0 }) }
    assert_raises(Erx::Error) { export(changes: { 'inventory_bytes' => 100 }) }
    assert Dir.empty?(@destination)
  end

  def test_pending_walk_entries_share_one_global_budget
    run_evidence
    parent = CT_ROOT
    5.times do
      5.times { |index| write(parent + "/z#{index}") }
      parent += '/a'
      FileUtils.mkdir_p(File.join(@source, parent))
    end
    directories = CountingDirectories.new
    result = export(changes: { 'entries' => 20 }, list_source_directory: directories.method(:each_child))
    assert_operator directories.visited, :<=, 21
    assert_equal 'partial', result.fetch('state')
  end

  def test_long_unicode_copy_failures_fit_the_reserved_inventory_budget
    skip 'permission-denial fixture requires an unprivileged user' if Process.uid.zero?
    run_evidence
    unreadable = 120.times.map do |index|
      path = write(CT_ROOT + '/' + "\u00e9" * 120 + index.to_s)
      File.chmod(0, path)
      path
    end
    result = export(changes: { 'inventory_bytes' => 100_000 })
    assert_equal result, verify(changes: { 'inventory_bytes' => 100_000 })
  ensure
    unreadable.to_a.each { |path| File.chmod(0o600, path) }
  end

  def test_oversized_omission_path_is_bounded_and_marked_truncated
    write('result.json', '{}')
    write('logs/' + "\u00e9" * 100)
    result = export(operation: 'probe', suite: nil, changes: { 'path_bytes' => 16 })
    assert_equal result, verify(changes: { 'path_bytes' => 16 })
    assert result.fetch('omissions').any? { |issue| issue['path_truncated'] == true }
  end

  def test_junit_named_runner_log_does_not_count_as_a_case_report
    run_evidence
    write('logs/junit_report.xml', 'ancillary runner attachment')
    result = export
    assert_equal 'complete', result.fetch('mandatory_evidence')
    refute result.fetch('omissions').any? { |issue| issue.fetch('reason') == 'ambiguous_junit' }
    assert_equal result, verify
  end

  def test_host_rejects_a_forged_private_fixture_file
    run_evidence
    export
    inventory = read_inventory
    path = CT_ROOT + '/ct_run/log_private/hidden'
    FileUtils.mkdir_p(File.dirname(File.join(@destination, path)), mode: 0o700)
    File.open(File.join(@destination, path), 'wb', 0o600) { |file| file.write('hidden') }
    inventory.fetch('files') << { 'path' => path, 'size' => 6, 'required' => false,
                                  'type' => 'file', 'sha256' => Digest::SHA256.hexdigest('hidden') }
    inventory.fetch('files').sort_by! { |file| file.fetch('path').b }
    replace_inventory(inventory)
    assert_raises(Erx::Error) { verify }
  end
end
