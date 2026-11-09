# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative 'runner'
require_relative 'output_directory'

module Erx
  # This is the extraction boundary for fetched and imported source archives.
  # Tar interprets the archive; only a verified, inspected tree is published.
  module Sources
    MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
    MAX_SOURCE_BYTES = 2 * 1024 * 1024 * 1024
    MAX_SOURCE_FILES = 200_000
    TAR_ENV = { 'TAR_OPTIONS' => nil, 'TAR_READER_OPTIONS' => nil,
                'TAR_WRITER_OPTIONS' => nil }.freeze
    module_function

    # A deps.lock members value: paths below a source's directory, separated by spaces,
    # each of plain components, none of them `.` or `..` or starting with `-`, and
    # none named twice.
    MEMBER = %r{\A[A-Za-z0-9_+][A-Za-z0-9_.+-]*(?:/[A-Za-z0-9_+][A-Za-z0-9_.+-]*)*\z}

    def valid_members?(text)
      members = text.split(' ')
      !members.empty? && members.size <= 64 && members.uniq == members &&
        members.all? { |member| member.bytesize <= 255 && MEMBER.match?(member) }
    end

    # members are the paths below source_directory to extract, or none for all of it.
    def unpack(archive:, sha256:, destination:, owner_root:, source_directory:, runner:, tar_program: 'tar', members: [])
      unless members.empty? || (source_directory != '.' && valid_members?(members.join(' ')))
        raise Error, 'invalid source archive members'
      end
      unless sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha256)
        raise Error, 'invalid source SHA-256'
      end
      unless source_directory == '.' || (source_directory.is_a?(String) && source_directory.bytesize.between?(1, 255) &&
             /\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z/.match?(source_directory))
        raise Error, 'invalid source archive directory'
      end
      destination = File.expand_path(destination)
      parent = OutputDirectory.check(root: owner_root, path: File.dirname(destination))
      destination = File.join(parent, File.basename(destination))
      if File.exist?(destination) || File.symlink?(destination)
        raise Error, "source extraction destination exists: #{destination}"
      end
      OutputDirectory.prepare(root: owner_root, path: parent)
      Dir.mktmpdir('.unpack-', File.dirname(destination)) do |temporary|
        snapshot = File.join(temporary, 'source.tar')
        File.open(archive, File::RDONLY | File::NONBLOCK) do |input|
          unless input.stat.file? && input.size <= MAX_ARCHIVE_BYTES
            raise Error, 'source archive must be a bounded regular file'
          end
          input.binmode
          File.open(snapshot, 'wb') do |output|
            size = IO.copy_stream(input, output, MAX_ARCHIVE_BYTES + 1)
            raise Error, 'source archive exceeds compressed size bound' if size > MAX_ARCHIVE_BYTES
          end
        end
        unless Digest::SHA256.file(snapshot).hexdigest == sha256
          raise Error, 'source archive SHA-256 mismatch'
        end
        tree = File.join(temporary, 'tree')
        Dir.mkdir(tree)
        runner.run([tar_program, '--no-same-owner', '--no-same-permissions',
                    '-xf', snapshot, '-C', tree, *members.map { |member| "#{source_directory}/#{member}" }],
                   name: 'extract-source', deadline: 120, env: TAR_ENV)
        validate_tree(tree)
        selected = tree
        if source_directory != '.'
          selected = File.join(tree, source_directory)
          unless Dir.children(tree) == [source_directory] && File.directory?(selected) && !File.symlink?(selected)
            raise Error, 'source archive has an unexpected top-level directory'
          end
          validate_tree(selected)
        end
        File.rename(selected, destination)
      end
    end

    def validate_tree(directory)
      root = File.realpath(directory)
      pending = [root]
      count = 0
      bytes = 0
      until pending.empty?
        visiting = pending.pop
        Dir.each_child(visiting) do |name|
          # Resolve from the directory being visited, without following links
          # during traversal. realpath below checks every link's destination.
          path = File.join(visiting, name)
          count += 1
          raise Error, 'source archive has too many members' if count > MAX_SOURCE_FILES
          stat = File.lstat(path)
          unless stat.file? || stat.directory? || stat.symlink?
            raise Error, 'source archive contains a special file'
          end
          if stat.symlink? && File.readlink(path).start_with?('/')
            raise Error, 'source archive contains an absolute symbolic link'
          end
          validate_link_target(path, root: root) if stat.symlink?
          resolved = File.realpath(path)
          unless resolved == root || resolved.start_with?(root + '/')
            raise Error, 'source archive link escapes extraction directory'
          end
          bytes += stat.size if stat.file?
          raise Error, 'source archive exceeds expanded size bound' if bytes > MAX_SOURCE_BYTES
          pending << path if stat.directory?
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP => error
      raise Error, "source archive has an unresolved link: #{error.message}"
    end
    private_class_method :validate_tree

    def validate_link_target(path, root:)
      cursor = File.dirname(path)
      File.readlink(path).split('/').each do |component|
        cursor = File.realpath(File.join(cursor, component))
        unless cursor == root || cursor.start_with?(root + '/')
          raise Error, 'source archive link leaves its published directory'
        end
      end
    end
    private_class_method :validate_link_target
  end
end
