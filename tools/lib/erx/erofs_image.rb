# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'pathname'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'fsimg'

module Erx
  # An EROFS image of a set of files, written by fsimg (Erx::Fsimg) with the packer's
  # options (docs/design-storage.md, "What each format holds"): every time fixed at 0,
  # a UUID fixed by the image's contents, every file owned by root, no extended
  # attributes, 4 KiB blocks and no compression, so the same files give the same bytes.
  #
  # The image is described to fsimg by an mtree manifest that names each directory
  # below the root (mode 0755; fsimg makes the root itself, 0755 and owned by root)
  # and each file (mode 0644) with root as its owner and each file's host
  # contents, size and SHA-256, so nothing of the host's umask, owners, times or
  # attributes reaches the image and no staging copy is made. fsimg verifies the
  # staged image before it publishes it (`cW`), and refuses a source whose size or
  # digest no longer matches the manifest, so the UUID names the bytes the image holds.
  # The image carries fsimg's default volume label, FSIMG, which nothing reads.
  class ErofsImage
    # The layout every erXos EROFS image shares: reproducible bytes with every time at 0
    # and 4 KiB blocks. The packer adds no compression; a test fixture may vary it.
    LAYOUT = %w[-F erofs -R -e 0 -o cluster=4096].freeze
    PACKER = [*LAYOUT, '-o', 'compression=none'].freeze
    # One name of a path inside the image: printable ASCII but '/'; paths join names by
    # '/'. Names are compared case-folded and kept within NAME_MAX, so a host whose file
    # system folds case or limits names would hold exactly what another host would.
    NAME = %r{\A[\x21-\x2e\x30-\x7e]+\z}
    NAME_MAX = 255
    DEADLINE = 300
    ROOT = File.expand_path('../../..', __dir__)

    # One file of the image as read once: its host path with every link resolved, its
    # size and its hex SHA-256.
    Source = Data.define(:path, :size, :digest)

    # A version 4 (random-form) UUID drawn from the SHA-256 of the image's sorted paths
    # and their files' digests (digests maps each path to its file's hex SHA-256), so two
    # builds of one image share it and images that hold different files do not.
    def self.uuid(digests)
      listing = digests.sort.map { |path, digest| "#{path} #{digest}\n" }.join
      bytes = Digest::SHA256.digest(listing).bytes.first(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.pack('C*').unpack1('H*')
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
    end

    # files maps each path inside the image to the host file it holds. A path is
    # refused unless it is relative and made of plain names, and a path that is also
    # another's directory is refused, so the manifest describes exactly files.
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

    # Each path's Source. A host file that is a link, or not a regular file, is refused
    # before anything reads it.
    def self.sources(files)
      files.to_h do |path, source|
        File.open(source, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
          raise Error, "an EROFS image's file is not a regular file: #{source}" unless input.stat.file?

          digest = Digest::SHA256.new
          size = 0
          while (chunk = input.read(1 << 20))
            digest << chunk
            size += chunk.bytesize
          end
          [path, Source.new(path: File.realpath(source), size: size, digest: digest.hexdigest)]
        end
      end
    rescue SystemCallError, IOError => error
      raise Error, "cannot read the EROFS image's files: #{error.message}"
    end

    # The deepest directory that holds every source, which fsimg is given as the
    # manifest's content directory: each contents= path is relative to it. Each
    # source's directory is taken as its chain of ancestors, outermost ('/') first,
    # and the answer is the last ancestor every chain shares.
    def self.content_directory(sources)
      chains = sources.each_value.map { |source| Pathname.new(File.dirname(source.path)).descend.map(&:to_s) }
      chains.reduce { |shared, chain| shared.take_while.with_index { |directory, index| chain[index] == directory } }.last
    end

    # The manifest's entries: each directory below the root and each file, sorted by path.
    def self.entries(sources, base:)
      owner = { 'uid' => 0, 'gid' => 0 }
      directories = sources.keys.flat_map { |path| parents(path) }.uniq.sort.map do |path|
        Fsimg::Entry.new(path: path, keywords: { 'type' => 'dir', 'mode' => '0755', **owner })
      end
      prefix = base == '/' ? '/' : "#{base}/"
      files = sources.sort.map do |path, source|
        Fsimg::Entry.new(path: path, keywords: { 'type' => 'file', 'mode' => '0644', **owner, 'size' => source.size,
                                                 'sha256digest' => source.digest,
                                                 'contents' => source.path.delete_prefix(prefix) })
      end
      directories + files
    end

    def initialize(runner:, root: ROOT)
      @runner = runner
      @root = root
    end

    # The built fsimg's path, refused unless it is the pinned build (Fsimg.locate) and
    # reports the pinned version.
    def check_tools = Fsimg.checked(root: @root, runner: @runner)

    # Writes the image of files as output, which must not exist, and returns its path.
    # The manifest and the image are written in a private directory beside output and
    # the image is linked to output whole, so a failed write leaves nothing at output and
    # an existing output, a link included, is refused. name labels the run's log.
    def write(files:, name:, output:)
      output = File.expand_path(output)
      self.class.check_files(files)
      fsimg = check_tools
      sources = self.class.sources(files)
      base = self.class.content_directory(sources)
      uuid = self.class.uuid(sources.transform_values(&:digest))
      Dir.mktmpdir('.erx-erofs-', File.dirname(output)) do |workspace|
        manifest = File.join(workspace, 'image.mtree')
        image = File.join(workspace, 'image')
        File.write(manifest, Fsimg.mtree(self.class.entries(sources, base: base)))
        @runner.run([fsimg, 'cW', '-f', image, *PACKER, '-o', "uuid=#{uuid}", '-C', base, "@#{manifest}"],
                    name: "fsimg-erofs-#{name}", deadline: DEADLINE)
        File.link(image, output)
      end
      output
    rescue SystemCallError => error
      raise Error, "cannot write the EROFS image #{output}: #{error.message}"
    end
  end
end
