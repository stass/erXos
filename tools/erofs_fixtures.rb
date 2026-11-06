#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'lib/erx/erofs_image'

# Writes the EROFS reader's fixture images (test/fixtures/erofs) with the host's
# mkfs.erofs, the packer's tool, from one tree this script declares, and the tree's
# expected view, test/fixtures/erofs/tree.terms, which the reader's EUnit cases and its
# fuzz target compare with what the reader answers. The tree is the input mkfs.erofs
# packs, so the comparison does not rest on the writer's reading of its own format.
#
# Each image is written with the packer's options (docs/design-storage.md, Data
# model): a fixed time for every file, a fixed UUID, every file owned by root, no
# extended attributes and 4 KiB blocks, and then with the options that vary what
# the reader meets: extended inodes and an inline xattr area on the root, the plain
# data layout only, and, for the refusals, LZ4 compression and chunked files.
#
# Usage: ruby tools/erofs_fixtures.rb [MKFS]   (default: mkfs.erofs on PATH)
module ErofsFixtures
  ROOT = File.expand_path('..', __dir__)
  OUT = File.join(ROOT, 'test/fixtures/erofs')
  # The packer's own options (Erx::ErofsImage::PACKER) and the fixtures' fixed UUID.
  PACKER = [*Erx::ErofsImage::PACKER, '-U', '6572786f-732d-6572-6f66-732d74657374'].freeze
  IMAGES = {
    'compact' => [],
    'extended' => %w[-E force-inode-extended --root-xattr-isize=64],
    'plain' => %w[-E noinline_data],
    'lz4' => %w[-zlz4],
    'chunked' => %w[--chunksize=4096]
  }.freeze

  # A regular file's bytes are a function of its size and seed, which the Erlang side
  # recomputes: byte i is (i * 7 + seed) mod 256.
  File_ = Data.define(:names, :size, :seed)
  Dir_ = Data.define(:names)
  Link = Data.define(:names, :target)
  # A second name for a file already declared.
  Hard = Data.define(:names, :of)

  MANY = (0...200).map { |index| format('entry-%04d-with-a-name-long-enough-to-fill-blocks', index) }.freeze
  TREE = [
    File_.new(names: %w[empty], size: 0, seed: 0),
    File_.new(names: %w[small], size: 100, seed: 1),
    File_.new(names: %w[block], size: 4096, seed: 2),
    File_.new(names: %w[big], size: 3 * 4096 + 100, seed: 3),
    Hard.new(names: %w[small-again], of: %w[small]),
    Dir_.new(names: %w[a]), Dir_.new(names: %w[a b]), Dir_.new(names: %w[a b c]),
    File_.new(names: %w[a b c leaf], size: 10, seed: 4),
    Link.new(names: %w[to-small], target: 'small'),
    Link.new(names: %w[to-b], target: '/a/b'),
    Link.new(names: %w[a b up], target: '../..'),
    Dir_.new(names: %w[many]),
    *MANY.each_with_index.map { |name, index| File_.new(names: ['many', name], size: 0, seed: index) }
  ].freeze

  module_function

  def bytes(size, seed) = (0...size).map { |index| ((index * 7) + seed) % 256 }.pack('C*')

  def build(tree_root)
    FileUtils.mkdir_p(tree_root)
    TREE.each do |entry|
      path = File.join(tree_root, *entry.names)
      case entry
      in Dir_ then FileUtils.mkdir_p(path)
      in File_ then File.binwrite(path, bytes(entry.size, entry.seed))
      in Link then File.symlink(entry.target, path)
      in Hard then File.link(File.join(tree_root, *entry.of), path)
      end
    end
  end

  def erlang_names(names) = "[#{names.map { |name| "<<\"#{name}\">>" }.join(', ')}]"

  # The expected view: each file with its names from the root, and each directory
  # with its children's names in the reader's order, bytewise.
  def terms
    children = TREE.group_by { |entry| entry.names[0..-2] }
    directories = [[]] + TREE.grep(Dir_).map(&:names)
    lines = TREE.map do |entry|
      case entry
      in File_ then "{regular, #{erlang_names(entry.names)}, #{entry.size}, #{entry.seed}}."
      in Hard
        original = TREE.find { |other| other.is_a?(File_) && other.names == entry.of }
        "{regular, #{erlang_names(entry.names)}, #{original.size}, #{original.seed}}."
      in Link then "{symlink, #{erlang_names(entry.names)}, <<\"#{entry.target}\">>}."
      in Dir_ then nil
      end
    end.compact
    lines += directories.map do |names|
      listed = children.fetch(names, []).map { |entry| entry.names.last }.sort
      "{directory, #{erlang_names(names)}, #{erlang_names(listed)}}."
    end
    "%% Written by tools/erofs_fixtures.rb: the tree every fixture image holds.\n#{lines.join("\n")}\n"
  end

  def run(mkfs)
    FileUtils.mkdir_p(OUT)
    Dir.mktmpdir('erofs-fixtures') do |work|
      tree_root = File.join(work, 'tree')
      build(tree_root)
      IMAGES.each do |name, options|
        image = File.join(OUT, "#{name}.img")
        FileUtils.rm_f(image)
        output, status = Open3.capture2e(mkfs, *PACKER, *options, image, tree_root, stdin_data: '')
        raise "#{mkfs} #{name}: #{output}" unless status.success?
      end
    end
    File.write(File.join(OUT, 'tree.terms'), terms)
  end
end

ErofsFixtures.run(ARGV.fetch(0, 'mkfs.erofs')) if $PROGRAM_NAME == __FILE__
