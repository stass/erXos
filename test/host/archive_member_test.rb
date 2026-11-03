# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/archive_member'

class ArchiveMemberTest < Minitest::Test
  def with_duplicate_archive
    Dir.mktmpdir('erx-ar-') do |root|
      program = ENV.fetch('ERX_AR', 'llvm-ar')
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      %w[first second].each { |name| FileUtils.mkdir_p(File.join(root, name)) }
      first = File.join(root, 'first/namespace.o')
      second = File.join(root, 'second/namespace.o')
      unique = File.join(root, 'unique.o')
      File.binwrite(first, 'first namespace implementation')
      File.binwrite(second, 'second namespace implementation with different symbols')
      File.binwrite(unique, 'unique object000')
      archive = File.join(root, 'fixture.a')
      runner.run([program, 'qc', '--', archive, first, second, unique], name: 'create-duplicate-archive', deadline: 30)
      yield root, program, runner, File.binread(archive)
    end
  end

  def test_duplicate_selected_name_is_refused_before_extracting_either_member
    with_duplicate_archive do |root, program, runner, bytes|
      operations = []
      reader = Object.new
      reader.define_singleton_method(:run) do |argv, **options|
        operations << argv.fetch(1)
        runner.run(argv, **options)
      end
      error = assert_raises(Erx::Error) do
        Erx::ArchiveMember.sha256(bytes: bytes, member: 'namespace.o', runner: reader,
          program: program, owner_root: root, directory: root, name: 'check-duplicate')
      end
      assert_includes error.message, 'ambiguous'
      refute_includes operations, 'p'
    end
  end

  def test_unselected_duplicates_do_not_prevent_reading_a_unique_member
    with_duplicate_archive do |root, program, runner, bytes|
      actual = Erx::ArchiveMember.sha256(bytes: bytes, member: 'unique.o', runner: runner,
        program: program, owner_root: root, directory: root, name: 'check-unique')
      output = Dir.glob(File.join(root, 'logs/check-unique-*.log')).map { |path| File.binread(path).inspect }.join("\n")
      assert_equal Digest::SHA256.hexdigest('unique object000'), actual, output
    end
  end
end
