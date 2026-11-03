# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/fiasco'

class FiascoReproducibleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @fiasco = Erx::Fiasco.new(root: ROOT)
  end

  def test_assembly_is_identical_and_contains_no_operator_identity
    @fiasco.build(jobs: 4)
    first = File.binread(@fiasco.image_path)
    @fiasco.send(:build_image, kernel: File.join(ROOT, 'build/fiasco/kernel'),
                 users: File.join(ROOT, 'build/fiasco/users'))
    second = File.binread(@fiasco.image_path)
    File.binwrite(File.join(ROOT, 'build/fiasco/repro-assembly-first.elf'), first)
    File.binwrite(File.join(ROOT, 'build/fiasco/repro-assembly-second.elf'), second)
    assert_equal Digest::SHA256.hexdigest(first), Digest::SHA256.hexdigest(second)
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    listing = runner.run(['perl', File.join(ROOT, 'build/fiasco/source/tool/bin/l4image'),
                          '-i', @fiasco.image_path, 'attr', '--list'],
                         name: 'fiasco-attributes', deadline: 10)
    attributes = File.binread(listing.fetch('log')).lines
    %w[l4i:creation- l4i:modification- l4i:sequence].each do |attribute|
      refute attributes.any? { |line| line.start_with?("'#{attribute}") },
             "operator metadata in image: #{attribute}"
    end
  end

  def test_two_clean_builds_are_identical
    clean_outputs
    @fiasco.build(jobs: 4)
    first = Digest::SHA256.file(@fiasco.image_path).hexdigest
    FileUtils.copy_file(@fiasco.image_path, File.join(ROOT, 'build/fiasco/repro-clean-first.elf'))
    clean_outputs
    @fiasco.build(jobs: 4)
    FileUtils.copy_file(@fiasco.image_path, File.join(ROOT, 'build/fiasco/repro-clean-second.elf'))
    assert_equal first, Digest::SHA256.file(@fiasco.image_path).hexdigest
  end

  def test_built_image_contains_no_absolute_host_paths
    @fiasco.build(jobs: 4)
    refute File.binread(@fiasco.image_path).include?(ROOT.b),
           'absolute source/build root embedded in boot image'
  end

  private

  def clean_outputs
    %w[kernel users images source].each do |name|
      directory = File.join(ROOT, 'build/fiasco', name)
      FileUtils.remove_entry(directory) if File.exist?(directory)
    end
  end
end
