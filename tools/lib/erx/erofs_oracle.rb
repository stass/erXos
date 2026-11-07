# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'error'
require_relative 'generated'
require_relative 'bounded_file'
require_relative 'erofs_image'
require_relative 'erofs_manifest'
require_relative 'linux_guest'
require_relative 'output_directory'
require_relative '../../erofs_fixtures'

module Erx
  # The EROFS oracle (docs/design-storage.md, Reading EROFS images): checks each image
  # with upstream's fsck.erofs, mounts all of them with Linux's EROFS driver in the
  # Linux guest (Erx::LinuxGuest) and with erXos's reader, erx_erofs, on the host's
  # stock OTP (test/erlang/erx_erofs_manifest.erl), and compares the two views file by
  # file (Erx::ErofsManifest.compare). An image passes when fsck.erofs accepts it, Linux
  # mounts it, and the reader sees the same files with the same metadata and bytes, or,
  # for an image whose refusal is expected, refuses it with that error.
  class ErofsOracle
    # An image to check: its file, and the error the reader's mount is expected to
    # answer, or nil when the reader must read it whole.
    Image = Data.define(:path, :refusal)

    # Every fixture tools/erofs_fixtures.rb writes, by name, with the refusal it expects.
    def self.fixtures(root)
      ErofsFixtures::IMAGES.keys.to_h do |name|
        ["test/fixtures/erofs/#{name}.img",
         Image.new(path: File.join(root, 'test/fixtures/erofs', "#{name}.img"), refusal: ErofsFixtures::REFUSED[name])]
      end
    end

    READER_SOURCES = %w[otp/erts/preloaded/src/erx_verity.erl otp/erts/preloaded/src/erx_erofs.erl
                        otp/erts/preloaded/src/erx_erofs_file.erl test/erlang/erx_erofs_tests.erl
                        test/erlang/erx_erofs_manifest.erl].freeze
    # erx_abi.hrl, which the readers include, is generated into build/gen.
    READER_INCLUDES = [File.join(Generated::OUTPUT, 'erlang/apps/erx/include'), 'otp/lib/kernel/include'].freeze

    # One image's result: the files Linux saw (nil when it did not mount the image),
    # the reader's refusal, and what keeps the image from passing. Every outcome is of
    # an image fsck.erofs accepted: call raises on the first image it does not.
    Outcome = Data.define(:name, :files, :refusal, :problems) do
      def passed? = problems.empty?
    end

    # environment carries ERX_ERL and ERX_ERLC, the host's stock OTP.
    def initialize(root:, runner:, environment:, guest: LinuxGuest.new(root: root, runner: runner),
                   erofs: ErofsImage.new(runner: runner))
      @root = root
      @runner = runner
      @environment = environment
      @guest = guest
      @erofs = erofs
    end

    # images: names (what the report calls each image) to Images. Answers an Outcome per
    # image, in order.
    def call(images, accel: 'hvf')
      paths = images.values.map(&:path)
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/erofs-oracle'))
      Dir.mktmpdir('run-', parent) do |work|
        images.each_with_index { |(name, image), index| fsck(name, image.path, File.join(work, "fsck-#{index}")) }
        boot_files = @guest.prepare(work)
        linux = manifest('Linux guest', @guest.run(boot_files, images: paths, accel: accel), images.size)
        reader = manifest('reader', reader_log(paths, work), images.size)
        images.zip(linux, reader).map { |(name, image), seen, read| outcome(name, image, seen, read) }
      end
    end

    private

    def fsck(name, path, extract)
      raise Error, "#{Terminal.escape(name)}: no image file at #{Terminal.escape(path)}" unless File.file?(path)

      @erofs.check(path: path, extract: extract)
    rescue CommandError => error
      raise Error, "#{Terminal.escape(name)}: fsck.erofs refuses the image; log: #{error.result.fetch('log')}"
    end

    def outcome(name, image, linux, reader)
      files = linux.entries&.size
      if linux.refusal.nil? && reader.refusal && image.refusal == reader.refusal
        return Outcome.new(name: name, files: files, refusal: reader.refusal, problems: [])
      end

      Outcome.new(name: name, files: files, refusal: reader.refusal,
                  problems: ErofsManifest.compare(linux: linux, reader: reader))
    end

    # The views a log holds, one per image, or Erx::Error naming the side and the log.
    def manifest(side, log, count)
      views = ErofsManifest.parse(BoundedFile.read(log, maximum: LinuxGuest::MAX_SERIAL_BYTES))
      raise Error, "#{views.size} images in the manifest, #{count} attached" unless views.size == count

      views
    rescue Error => error
      raise Error, "#{side}: #{error.message}; log: #{log}"
    end

    # Compiles the reader and its manifest printer for the host's stock OTP and runs it
    # over the images; answers the path of the log that holds its manifest.
    def reader_log(paths, work)
      code = File.join(work, 'reader')
      Dir.mkdir(code)
      Generated.ensure(root: @root)
      includes = READER_INCLUDES.flat_map { |directory| ['-I', File.join(@root, directory)] }
      @runner.run([@environment.fetch('ERX_ERLC'), '-Werror', *includes, '-o', code,
                   *READER_SOURCES.map { |path| File.join(@root, path) }],
                  name: 'erofs-oracle-compile', deadline: 120, env: @environment)
      @runner.run([@environment.fetch('ERX_ERL'), '-noshell', '-pa', code, '-run', 'erx_erofs_manifest', 'main', *paths],
                  name: 'erofs-oracle-reader', deadline: 600, env: @environment,
                  output_limit: LinuxGuest::MAX_SERIAL_BYTES).fetch('log')
    end
  end
end
