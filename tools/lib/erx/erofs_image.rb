# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'error'

module Erx
  # An EROFS image of a set of files, written by upstream's mkfs.erofs with the packer's
  # options (docs/design-storage.md, "What each format holds"): a fixed time for every
  # file, a UUID fixed by the image's contents, every file owned by root, no extended
  # attributes, 4 KiB blocks and no compression, so the same files give the same bytes.
  #
  # mkfs.erofs packs a directory, so the files are first copied into a private staging
  # tree whose modes this module sets itself (0755 for a directory, 0644 for a file),
  # and nothing of the host's umask, owners, times or attributes reaches the image.
  # mkfs.erofs and fsck.erofs are host tools at the pinned erofs-utils release (TOOLS),
  # run as subprocesses by argument vector; a tool reporting another version is refused.
  class ErofsImage
    VERSION = '1.9.4'
    TOOLS = %w[mkfs.erofs fsck.erofs].freeze
    PACKER = %w[-b 4096 -T 0 --all-time --all-root -x -1].freeze
    # One name of a path inside the image: printable ASCII but '/'; paths join names by
    # '/'. Names are compared case-folded and kept within NAME_MAX, so a host whose file
    # system folds case or limits names stages exactly what another host would.
    NAME = %r{\A[\x21-\x2e\x30-\x7e]+\z}
    NAME_MAX = 255
    DEADLINE = 300

    # The version line each tool prints first: "mkfs.erofs (erofs-utils) 1.9.4".
    def self.version_line(tool) = /\A#{Regexp.escape(tool)} \(erofs-utils\) #{Regexp.escape(VERSION)}\s*\z/

    # A version 4 (random-form) UUID drawn from the SHA-256 of the image's sorted paths
    # and their files' digests, so two builds of one image share it and images that hold
    # different files do not.
    def self.uuid(files)
      listing = files.sort.map { |path, source| "#{path} #{Digest::SHA256.file(source).hexdigest}\n" }.join
      bytes = Digest::SHA256.digest(listing).bytes.first(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.pack('C*').unpack1('H*')
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
    end

    # files maps each path inside the image to the host file it holds. A path is
    # refused unless it is relative and made of plain names, and a path that is also
    # another's directory is refused, so the staging tree is exactly files.
    def self.check_files(files)
      raise Error, 'an EROFS image needs a map of its files' unless files.is_a?(Hash) && !files.empty?

      files.each_key do |path|
        names = path.is_a?(String) ? path.split('/', -1) : []
        unless !names.empty? && names.all? { |name| NAME.match?(name) && name.bytesize <= NAME_MAX && !%w[. ..].include?(name) }
          raise Error, "an EROFS image path must be relative plain names: #{path.inspect}"
        end
      end
      directories = files.keys.flat_map { |path| parents(path) }.uniq
      folded = (files.keys + directories).group_by(&:downcase).values.find { |spellings| spellings.size > 1 }
      raise Error, "an EROFS image path is spelled twice or is both a file and a directory: #{folded.first}" if folded

      files
    end

    # The directories above path, outermost first.
    def self.parents(path)
      names = path.split('/')
      (1...names.size).map { |count| names.first(count).join('/') }
    end

    def initialize(runner:)
      @runner = runner
    end

    # Refuses a mkfs.erofs or fsck.erofs that is missing or not the pinned release.
    def check_tools
      TOOLS.each do |tool|
        identity = @runner.run([tool, '--version'], name: "check-#{tool.tr('.', '-')}-version", deadline: 30)
        first_line = BoundedFile.read(identity.fetch('log'), maximum: 65_536).lines.first.to_s
        unless self.class.version_line(tool).match?(first_line)
          raise Error, "#{tool} must be erofs-utils #{VERSION}, as docs/design.md's dependency table pins it; " \
                       "it reports #{first_line.strip.inspect}"
        end
      end
      self
    end

    # Writes the image of files as output, which must not exist, and returns its path.
    # The staging tree and the image are written in a private directory beside output and
    # the image is linked to output whole, so a failed write leaves nothing at output and
    # an existing output, a link included, is refused. name labels the run's log.
    def write(files:, name:, output:)
      self.class.check_files(files)
      check_tools
      Dir.mktmpdir('.erx-erofs-', File.dirname(output)) do |workspace|
        tree = File.join(workspace, 'tree')
        image = File.join(workspace, 'image')
        stage(files, tree)
        @runner.run(['mkfs.erofs', *PACKER, '-U', self.class.uuid(files), image, tree],
                    name: "mkfs-erofs-#{name}", deadline: DEADLINE)
        File.link(image, output)
      end
      output
    rescue SystemCallError => error
      raise Error, "cannot write the EROFS image #{output}: #{error.message}"
    end

    # Runs fsck.erofs over the image that starts offset bytes into path, extracting its
    # files into directory, which must not exist.
    def check(path:, offset: 0, extract:)
      check_tools
      @runner.run(['fsck.erofs', "--offset=#{offset}", "--extract=#{extract}", '--no-preserve', path],
                  name: 'fsck-erofs', deadline: DEADLINE)
      extract
    end

    private

    def stage(files, tree)
      Dir.mkdir(tree)
      File.chmod(0o755, tree)
      files.keys.flat_map { |path| self.class.parents(path) }.uniq.sort.each do |directory|
        path = File.join(tree, directory)
        Dir.mkdir(path)
        File.chmod(0o755, path)
      end
      files.sort.each do |path, source|
        destination = File.join(tree, path)
        File.open(source, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
          raise Error, "an EROFS image's file is not a regular file: #{source}" unless input.stat.file?

          File.open(destination, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) do |output|
            IO.copy_stream(input, output)
          end
        end
        File.chmod(0o644, destination)
      end
    rescue SystemCallError, IOError => error
      raise Error, "cannot stage the EROFS image's files: #{error.message}"
    end
  end
end
