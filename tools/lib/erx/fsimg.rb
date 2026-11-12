# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # fsimg, the host tool that writes and verifies every EROFS image erXos makes
  # (docs/design-storage.md, "What each format holds"): built for the development
  # host from the pinned source (deps.lock, id `fsimg`) into build/fsimg, and run as
  # a subprocess by argument vector, never linked.
  #
  # fsimg reads the files of an image from an mtree(5) manifest, which names each
  # entry's type, owner, mode and host contents, so a caller describes the image it
  # wants instead of staging a tree whose host metadata could leak in. Fsimg.mtree
  # writes such a manifest from entries the caller has already checked.
  module Fsimg
    SOURCE_ID = 'fsimg'
    OUTPUT = 'build/fsimg'
    STAMP = 'build.json'
    # The first line `fsimg -V` prints at the pinned commit.
    VERSION_LINE = 'fsimg 0.1.0'

    class MissingBuild < Error; end
    class StaleBuild < Error; end

    # One manifest line: the entry's path inside the image, relative and
    # '/'-separated, and its keywords in the order they are written. Each keyword is
    # one of KEYWORDS; the `link` and `contents` values are paths and are encoded as
    # the path is, and every other value must be a WORD.
    Entry = Data.define(:path, :keywords)

    # Bytes written as themselves in an encoded path; every other byte is written
    # as a backslash and three octal digits, which fsimg's manifest reader decodes
    # (vis(3)'s octal form), so no name can open a comment, split a word or start
    # a keyword.
    PLAIN = /[A-Za-z0-9._\/-]/
    ENCODED_KEYWORDS = %w[link contents].freeze
    KEYWORDS = (%w[type mode uid gid size sha256digest] + ENCODED_KEYWORDS).freeze
    # A plain keyword value: printable ASCII with no backslash, so it is one word
    # and decodes to itself.
    WORD = /\A[\x21-\x5b\x5d-\x7e]+\z/

    module_function

    # The lock entry for fsimg, read whole and checked by DependencySchema.
    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    # The built fsimg's path, refused unless its build record names deps.lock's
    # pin and this file's recipe, so a binary built from another pin or recipe is
    # never run.
    def locate(root:)
      output = File.join(File.expand_path(root), OUTPUT)
      binary = File.join(output, 'fsimg')
      stamp_path = File.join(output, STAMP)
      unless File.file?(binary) && File.file?(stamp_path)
        raise MissingBuild, "fsimg is not built: #{binary} is missing; run tools/erx build fsimg"
      end

      stamp = begin
        JsonInput.parse(BoundedFile.read(stamp_path, maximum: 65_536), max_bytes: 65_536, label: 'fsimg build record')
      rescue JsonInput::Unsupported
        # A record this Ruby cannot parse at all is the host's problem, not a stale build.
        raise
      rescue Error => e
        raise StaleBuild, "fsimg in #{output} has an unreadable build record (#{e.message}); run tools/erx build fsimg"
      end
      unless stamp.is_a?(Hash) && stamp['source'] == source_record(root: root) && stamp['recipe'] == Build::RECIPE
        raise StaleBuild, "fsimg in #{output} was built from another source or recipe; run tools/erx build fsimg"
      end

      binary
    end

    # The built fsimg's path, refused unless it is the pinned build (locate) and reports
    # the pinned version.
    def checked(root:, runner:)
      fsimg = locate(root: root)
      identity = runner.run([fsimg, '-V'], name: 'check-fsimg-version', deadline: 30)
      first_line = BoundedFile.read(identity.fetch('log'), maximum: 65_536).lines.first.to_s.strip
      unless first_line == VERSION_LINE
        raise Error, "fsimg must report #{VERSION_LINE.inspect}, as deps.lock pins it; it reports #{first_line.inspect}"
      end

      fsimg
    end

    # The manifest text for entries, one line each, in the order given. A keyword
    # outside KEYWORDS or a plain value that is not a WORD is refused, so no value can
    # split a word or start a line.
    def mtree(entries)
      lines = entries.map do |entry|
        keywords = entry.keywords.map do |key, value|
          raise Error, "fsimg manifest keyword not allowed: #{key.inspect}" unless KEYWORDS.include?(key)

          encoded = ENCODED_KEYWORDS.include?(key)
          text = encoded ? encode(value) : value.to_s
          raise Error, "fsimg manifest value is not a plain word: #{key}" unless encoded || WORD.match?(text)

          "#{key}=#{text}"
        end
        [encode("./#{entry.path}"), *keywords].join(' ')
      end
      "#mtree\n#{lines.map { |line| "#{line}\n" }.join}"
    end

    def encode(path) = path.b.each_char.map { |char| PLAIN.match?(char) ? char : format('\\%03o', char.ord) }.join

    # Builds fsimg for the host from the fetched tree into build/fsimg: the tree is
    # copied, since autoreconf writes into the tree it runs in, then configured out
    # of tree with libfsimg linked in statically and without the zstd and xz codecs,
    # which erXos's images do not use, so the program needs no host library beyond the
    # C library and zlib. Only the `fsimg` program is made. As for the rc oracle, the
    # build record names the pin and the recipe, not the host compiler, and the built
    # program is trusted as the development host's own files are.
    class Build
      # The recipe is this file: a change to it makes an older build stale.
      RECIPE = Digest::SHA256.file(__FILE__).hexdigest.freeze
      CONFIGURE = %w[--disable-shared --with-zstd=no --with-xz=no].freeze
      DEADLINE = 900

      def initialize(root:, runner:, jobs: 4)
        @root = File.expand_path(root)
        @runner = runner
        @jobs = jobs
      end

      def call
        source = Fsimg.source_record(root: @root)
        tree = Dependencies.new(root: @root, runner: @runner).fetched_tree(SOURCE_ID)
        build = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build'))
        Dir.mktmpdir('.fsimg-', build) do |work|
          copy = File.join(work, 'source')
          objects = File.join(work, 'objects')
          output = File.join(work, 'out')
          FileUtils.cp_r(tree, copy)
          [objects, output].each { |path| Dir.mkdir(path) }
          @runner.run(%w[autoreconf -fi], name: 'fsimg-autoreconf', deadline: DEADLINE, chdir: copy)
          @runner.run([File.join(copy, 'configure'), *CONFIGURE], name: 'fsimg-configure', deadline: DEADLINE, chdir: objects)
          @runner.run(['make', "-j#{@jobs}", 'fsimg'], name: 'fsimg-make', deadline: DEADLINE, chdir: objects)
          FileUtils.cp(File.join(objects, 'fsimg'), File.join(output, 'fsimg'))
          stamp = { 'source' => source, 'recipe' => RECIPE }
          File.write(File.join(output, STAMP), "#{JSON.pretty_generate(stamp)}\n")
          publish(output)
        end
        Fsimg.locate(root: @root)
      end

      private

      # The new output replaces the old whole: the old tree moves aside into the
      # work directory, which is deleted after the new one is in place.
      def publish(output)
        destination = File.join(@root, OUTPUT)
        raise Error, "fsimg output is a symbolic link: #{destination}" if File.symlink?(destination)

        previous = "#{output}.previous"
        File.rename(destination, previous) if File.exist?(destination)
        File.rename(output, destination)
      end
    end
  end
end
