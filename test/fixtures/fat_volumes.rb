# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative '../../tools/lib/erx/fsimg'

# The FAT server's test volumes: one tree, written by fsimg as a FAT16 volume of
# 1 KiB clusters and a FAT32 volume of 512-byte clusters, into a directory as
# fat16.img and fat32.img beside the tree itself, tree/. The tree holds a long
# name, a file of several clusters, an empty file and a directory two deep. Its
# times are FAT's first, so the bytes are reproducible.
module FatVolumes
  EPOCH = %w[-R -e 315532800].freeze
  VOLUMES = {
    'fat16.img' => ['-F', 'fat16', '-s', (8 * 1_048_576).to_s, '-L', 'STICK16', '-o', 'cluster=1024'],
    'fat32.img' => ['-F', 'fat32', '-s', (40 * 1_048_576).to_s, '-L', 'STICK32', '-o', 'cluster=512']
  }.freeze
  FILES = {
    'hello.txt' => "hello, stick\n",
    'empty' => '',
    'sub/Long File Name.dat' => (0...5000).map { |index| (index % 251).chr }.join,
    'sub/Deeper/x.TXT' => "deep\n"
  }.freeze

  module_function

  # Writes the tree and both volumes into directory, which the caller owns.
  def write(directory, root:)
    tree = File.join(directory, 'tree')
    FILES.each do |path, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(tree, path)))
      File.binwrite(File.join(tree, path), bytes)
    end
    fsimg = Erx::Fsimg.locate(root: root)
    VOLUMES.each do |name, arguments|
      output, status = Open3.capture2e(fsimg, 'cW', '-f', File.join(directory, name), *arguments, *EPOCH,
                                       '-C', tree, '.', stdin_data: '')
      raise "fsimg failed on #{name}: #{output}" unless status.success?
    end
  end
end
