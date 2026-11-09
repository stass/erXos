# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/image_fixture'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/runner'

# erx_image_plan (liberx/image_plan.c), the planner the Fiasco backend's
# erx_image_map reads an image entry with: the plan of an entry the pack tool
# wrote, and the refusals of the fields a bad manifest would carry past it.
class ImagePlanTest < Minitest::Test
  PAGE = ImageFixture::PAGE

  def setup
    @directory = Dir.mktmpdir('erx-image-plan-')
    @root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @planner = File.join(@directory, 'image-plan')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported image-plan sanitizer' unless (sanitizers - %w[address undefined]).empty?

    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *flags, *Erx::Generated.include_flags(root: @root), '-I', File.join(@root, 'include'),
                 File.join(@root, 'liberx/image_plan.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'tools/host/input.c'),
                 File.join(@root, 'tools/host/image_plan.c'), '-o', @planner],
                name: 'compile-image-plan', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def plan(bytes)
    path = File.join(@directory, 'entry.bin')
    File.binwrite(path, bytes)
    record = @runner.run([@planner, path], name: 'image-plan', deadline: 30)
    [record.fetch('exit_status'), File.read(record.fetch('log'))]
  rescue Erx::CommandError => error
    [error.result.fetch('exit_status'), File.read(error.result.fetch('log'))]
  end

  def refuse(bytes, reason)
    status, output = plan(bytes)
    assert_equal 1, status, output
    assert_match(/^error #{reason} /, output)
  end

  def test_plans_each_segment_from_its_file_offset
    status, output = plan(ImageFixture.valid)
    assert_equal 0, status, output
    assert_includes output, "plan fixed_base #{ImageFixture::FIXED_BASE} span #{3 * PAGE} entry #{ImageFixture::ENTRY} " \
                            'flags 1 nloads 2'
    assert_includes output, "load #{PAGE} 0 #{PAGE} #{PAGE} #{ImageFixture.prot('rx')}"
    assert_includes output, "load #{2 * PAGE} #{PAGE} 16 #{2 * PAGE} #{ImageFixture.prot('rw')}"
  end

  def test_refuses_a_manifest_of_another_magic_version_or_abi
    refuse(ImageFixture.patch(ImageFixture::MAGIC, 0x464c_457f, width: 4), 'image_magic')
    refuse(ImageFixture.patch(ImageFixture::VERSION, 2, width: 2), 'image_version')
    refuse(ImageFixture.patch(ImageFixture::ABI_VERSION, 0xffff_ffff, width: 4), 'image_abi_version')
  end

  def test_refuses_more_segments_than_the_limit
    count = ImageFixture.codec.constant('image_segments_max') + 1
    refuse(ImageFixture.patch(ImageFixture::NSEGMENTS, count, width: 2), 'image_segments')
  end

  def test_refuses_a_segment_past_the_entry_or_wrapping
    size = ImageFixture.segment_field(1, ImageFixture::FILE_SIZE)
    refuse(ImageFixture.patch(size, PAGE + 1, width: 8), 'segment_file')
    offset = ImageFixture.segment_field(1, ImageFixture::FILE_OFFSET)
    refuse(ImageFixture.patch(offset, (3 * PAGE) - 8, width: 8), 'segment_file')
    refuse(ImageFixture.patch(offset, (2**64) - PAGE, width: 8), 'segment_file')
  end

  def test_refuses_a_writable_executable_segment
    rwx = ImageFixture.prot('rw') | ImageFixture.prot('rx')
    refuse(ImageFixture.patch(ImageFixture.segment_field(0, ImageFixture::PROT), rwx, width: 4), 'segment_prot')
  end

  def test_refuses_overlapping_segments_and_an_entry_outside_code
    refuse(ImageFixture.patch(ImageFixture.segment_field(1, ImageFixture::MEM_OFFSET), 0, width: 8), 'segment_memory')
    refuse(ImageFixture.patch(ImageFixture::ENTRY_FIELD, PAGE + 8, width: 8), 'entry_not_executable')
  end

  def test_refuses_a_fixed_base_outside_user_space
    refuse(ImageFixture.patch(ImageFixture::FIXED_BASE_FIELD, 0, width: 8), 'image_base')
    refuse(ImageFixture.patch(ImageFixture::FIXED_BASE_FIELD, (2**64) - PAGE, width: 8), 'image_base')
  end
end
