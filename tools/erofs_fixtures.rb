#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'lib/erx/erofs_image'
require_relative 'lib/erx/fsimg'
require_relative 'lib/erx/runner'

# Writes the EROFS reader's fixture images (test/fixtures/erofs) with the built fsimg
# (Erx::Fsimg), the packer's tool, from one tree this script declares, and the tree's
# expected view, test/fixtures/erofs/tree.terms, which the reader's EUnit cases and its
# fuzz target compare with what the reader answers. The tree is the input fsimg packs,
# so the comparison does not rest on the writer's reading of its own format.
#
# The tree reaches fsimg as an mtree manifest: each file's bytes from a host tree of
# regular files, each directory and symbolic link described in the manifest alone. A
# second name of a file is a second file with the same bytes, since fsimg writes no
# hard links. Each image is written with the packer's options (Erx::ErofsImage::PACKER)
# and a fixed UUID, and then with what varies what the reader meets: every entry but
# the root owned by an id beyond 16 bits, which a compact inode cannot hold, so every
# inode but the root's is extended (fsimg makes the root itself, owned by root); and,
# for the refusal, LZ4 compression.
#
# Usage: ruby tools/erofs_fixtures.rb   (after `tools/erx build fsimg`)
module ErofsFixtures
  ROOT = File.expand_path('..', __dir__)
  OUT = File.join(ROOT, 'test/fixtures/erofs')
  UUID = '6572786f-732d-6572-6f66-732d74657374'
  # Each image: the owner of every entry and the packer options it differs in.
  Image = Data.define(:owner, :compression)
  IMAGES = {
    'compact' => Image.new(owner: 0, compression: 'none'),
    'extended' => Image.new(owner: 70_000, compression: 'none'),
    'lz4' => Image.new(owner: 0, compression: 'lz4')
  }.freeze
  # The images whose features the reader does not implement, and the error its mount
  # answers for each.
  REFUSED = { 'lz4' => 'enotsup' }.freeze

  # A regular file's bytes are a function of its size and seed, which the Erlang side
  # recomputes: byte i is (i * 7 + seed) mod 256.
  File_ = Data.define(:names, :size, :seed)
  Dir_ = Data.define(:names)
  Link = Data.define(:names, :target)
  # A second name for a file already declared, which reaches the image as a second
  # file with the same bytes.
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

  # The host tree: one regular file for each File_ and Hard entry, named by its path.
  def build(tree_root)
    TREE.each do |entry|
      case entry
      in File_ then write(tree_root, entry.names, bytes(entry.size, entry.seed))
      in Hard
        original = TREE.find { |other| other.is_a?(File_) && other.names == entry.of }
        write(tree_root, entry.names, bytes(original.size, original.seed))
      in Dir_ | Link then nil
      end
    end
  end

  def write(tree_root, names, contents)
    path = File.join(tree_root, *names)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  # The manifest of the tree, every entry owned by owner.
  def manifest(owner)
    ids = { 'uid' => owner, 'gid' => owner }
    TREE.map do |entry|
      path = entry.names.join('/')
      keywords = case entry
                 in Dir_ then { 'type' => 'dir', 'mode' => '0755' }
                 in File_ | Hard then { 'type' => 'file', 'mode' => '0644', 'contents' => path }
                 in Link then { 'type' => 'link', 'mode' => '0777', 'link' => entry.target }
                 end
      Erx::Fsimg::Entry.new(path: path, keywords: keywords.merge(ids))
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

  def run
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    fsimg = Erx::ErofsImage.new(runner: runner, root: ROOT).check_tools
    FileUtils.mkdir_p(OUT)
    Dir.mktmpdir('erofs-fixtures') do |work|
      tree_root = File.join(work, 'tree')
      build(tree_root)
      IMAGES.each do |name, image|
        manifest = File.join(work, "#{name}.mtree")
        File.write(manifest, Erx::Fsimg.mtree(manifest(image.owner)))
        output = File.join(OUT, "#{name}.img")
        FileUtils.rm_f(output)
        runner.run([fsimg, 'cW', '-f', output, *Erx::ErofsImage::LAYOUT, '-o', "compression=#{image.compression}",
                    '-o', "uuid=#{UUID}", '-C', tree_root, "@#{manifest}"],
                   name: "fsimg-fixture-#{name}", deadline: Erx::ErofsImage::DEADLINE)
      end
    end
    File.write(File.join(OUT, 'tree.terms'), terms)
  end
end

ErofsFixtures.run if $PROGRAM_NAME == __FILE__
