# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'socket'
require 'tmpdir'
require 'zlib'
require_relative 'error'
require_relative 'medium_image'
require_relative 'site_v64'

module Erx
  # Assembles the static website in build/site from four inputs: the page
  # sources in site/, a v64 tree SiteV64 built (the emulator the page runs
  # erXos on, with its licence notices), an erXos boot image, and the
  # source the image was built from. None of the built files is checked in.
  #
  # It also makes the disk the page attaches to the machine as its virtio
  # block device, on the virtio-mmio slot where the QEMU harness attaches
  # its guest's: a boot medium laid out by abi/medium.txt with every window
  # blank (blank_medium). The medium is 1.2 GiB, but only its partition
  # table holds bytes, so it is published as those bytes and the extents
  # they fill, and the page keeps it sparse.
  #
  # The image, the disk, terminal.js and v64's two files are stored under
  # names that carry their digests, and boot.json (fetched without the
  # cache's copy) and index.html name them, so a cache never serves a stale
  # file and files of two deployments never mix. The image is gzip-compressed; the
  # page decompresses it with DecompressionStream, so the static host needs
  # no Content-Encoding setup.
  #
  # The image carries the stopgap kernel's GPL-2.0 code, so the page links
  # the erXos source it was built from, a release tag or a commit, beside
  # the console (docs/design.md, "Licences and notices").
  module Site
    PAGE_FILES = %w[index.html style.css favicon.svg terminal.js].freeze
    MANIFEST = 'boot.json'
    # Marks a directory this step built; the server's route table skips it.
    MARKER = '.erx-site'
    REPOSITORY = 'https://github.com/stass/erXos'
    TAG = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/
    COMMIT = /\A[0-9a-f]{40}\z/
    SECTOR_BYTES = MediumImage::SECTOR_BYTES

    # One output file: where it goes under the site directory, where it comes
    # from, and whether it is stored gzip-compressed.
    Entry = Data.define(:path, :source, :gzip)
    # A disk of capacity bytes that holds content at extents, [offset, length]
    # pairs in bytes, sorted, apart and whole sectors, whose lengths sum to
    # content's; every other byte is zero.
    Disk = Data.define(:capacity, :extents, :content)
    # The erXos source an image was built from: a release tag or a commit.
    Source = Data.define(:ref) do
      def url = "#{REPOSITORY}/tree/#{ref}"
      def label = COMMIT.match?(ref) ? ref[0, 12] : ref
    end
    # entries: the files copied as they are; index: index.html's template;
    # names: the digest names; disk: the Disk; manifest: boot.json without
    # compressed_bytes, which only the written image gives.
    Plan = Data.define(:entries, :index, :names, :disk, :manifest)

    module_function

    # A release tag (letters, digits, '.', '_' and '-', no '..') or a full
    # commit hash; anything else is refused, since it lands in a URL and in
    # the page.
    def source(ref)
      unless ref.is_a?(String) && (COMMIT.match?(ref) || (TAG.match?(ref) && !ref.include?('..')))
        raise Error, "image source must be a release tag or a 40-hex commit: #{ref.inspect}"
      end

      Source.new(ref:)
    end

    # The name under which a file is published: its digest's first 16 hex
    # digits before its extension.
    def digest_name(name, digest)
      extension = File.extname(name)
      "#{File.basename(name, extension)}-#{digest[0, 16]}#{extension}"
    end

    # The disk of capacity bytes that pieces, a map from a sector to the
    # bytes written from it (whole sectors), fill: each run of adjacent
    # pieces is one extent. Raises Erx::Error for a piece that is not whole
    # sectors within the disk or that overlaps another.
    def disk(pieces:, capacity:)
      unless capacity.is_a?(Integer) && capacity.positive? && (capacity % SECTOR_BYTES).zero?
        raise Error, 'a disk is a positive whole number of sectors'
      end

      spans = pieces.map { |sector, bytes| disk_span(sector, bytes, capacity:) }.sort_by(&:first)
      spans.each_cons(2) do |(offset, length), (next_offset, _)|
        raise Error, "the disk's piece at byte #{next_offset} overlaps the one before it" if offset + length > next_offset
      end
      runs = spans.slice_when { |(offset, length), (next_offset, _)| offset + length != next_offset }
      Disk.new(capacity:, extents: runs.map { |run| [run.first.first, run.sum(&:last)].freeze }.freeze,
               content: pieces.sort_by(&:first).map(&:last).join.b.freeze)
    end

    # A piece's [offset, length] in bytes, once it is found to be whole
    # sectors within a disk of capacity bytes.
    def disk_span(sector, bytes, capacity:)
      unless sector.is_a?(Integer) && !sector.negative? && bytes.is_a?(String) && !bytes.empty? &&
             (bytes.bytesize % SECTOR_BYTES).zero? && (sector * SECTOR_BYTES) + bytes.bytesize <= capacity
        raise Error, "the disk's piece at sector #{sector.inspect} is not whole sectors within the disk"
      end

      [sector * SECTOR_BYTES, bytes.bytesize]
    end
    private_class_method :disk_span

    # The disk the page attaches: a boot medium whose data partition has the
    # layout's minimum length (128 MiB) and whose windows are all blank.
    # erx_blk_table admits it, and /data's littlefs volume formats itself
    # over the blank data window at the first boot (erx_lfs formats blocks
    # that hold no volume). Only the partition table's three records hold
    # bytes.
    def blank_medium
      data_sectors = MediumImage.constant('data_sectors_min')
      disk(pieces: MediumImage.records(data_sectors:), capacity: MediumImage.sectors(data_sectors:) * SECTOR_BYTES)
    end

    # Reads the inputs' sizes and digests and decides which file goes where.
    # Raises Erx::Error naming the first missing input.
    def inventory(root:, v64:, image:, source:, disk: blank_medium)
      page = PAGE_FILES.to_h { |name| [name, File.join(root, 'site', name)] }
      emulator = SiteV64::TARGETS.transform_values { |path| File.join(v64, path) }
      notices = SiteV64::NOTICES.transform_values { |path| File.join(v64, path) }
      missing = [*page.values, *emulator.values, *notices.values, image].reject { |path| File.file?(path) }
      raise Error, "site input missing: #{missing.first}" unless missing.empty?

      digest = ->(path) { Digest::SHA256.file(path).hexdigest }
      image_sha256 = digest.(image)
      disk_sha256 = Digest::SHA256.hexdigest(disk.content)
      names = { 'terminal.js' => digest_name('terminal.js', digest.(page.fetch('terminal.js'))),
                'image' => "image-#{image_sha256[0, 16]}.boot.gz", 'disk' => "disk-#{disk_sha256[0, 16]}.bin" }
              .merge(emulator.to_h { |name, path| [name, "v64/#{digest_name(name, digest.(path))}"] })
      entries = [Entry.new(path: 'style.css', source: page.fetch('style.css'), gzip: false),
                 Entry.new(path: 'favicon.svg', source: page.fetch('favicon.svg'), gzip: false),
                 Entry.new(path: names.fetch('terminal.js'), source: page.fetch('terminal.js'), gzip: false),
                 *emulator.map { |name, path| Entry.new(path: names.fetch(name), source: path, gzip: false) },
                 *notices.map { |name, path| Entry.new(path: "v64/#{name}", source: path, gzip: false) },
                 Entry.new(path: names.fetch('image'), source: image, gzip: true)]
      manifest = { image: names.fetch('image'), bytes: File.size(image), sha256: image_sha256,
                   emulator: { module: names.fetch('libv86.mjs'), wasm: names.fetch('v86-arm64.wasm'),
                               bytes: emulator.values.sum { |path| File.size(path) } },
                   disk: { file: names.fetch('disk'), bytes: disk.content.bytesize, sha256: disk_sha256,
                           capacity: disk.capacity, extents: disk.extents },
                   source: { ref: source.ref, url: source.url } }
      Plan.new(entries:, index: page.fetch('index.html'), names:, disk:, manifest:)
    end

    # index.html with its {{name}} placeholders filled in. Every value is
    # HTML-escaped; an unknown placeholder raises.
    def render_index(template, terminal:, source:)
      values = { 'terminal_js' => terminal, 'source_url' => source.url, 'source_label' => source.label }
      template.gsub(/\{\{([a-z_]+)\}\}/) do
        key = Regexp.last_match(1)
        raise Error, "index.html: unknown placeholder {{#{key}}}" unless values.key?(key)

        CGI.escapeHTML(values.fetch(key))
      end
    end

    # The effects: builds the site in a fresh sibling of out and renames it
    # into place, so an interrupted build leaves out as it was. Only a
    # directory this step built (it holds the MARKER file) is replaced, so a
    # mistyped path never deletes anything else.
    def publish(plan, out:)
      if File.exist?(out) && !File.file?(File.join(out, MARKER))
        raise Error, "refusing to replace #{out}: not built by tools/build_site.rb"
      end

      FileUtils.mkdir_p(File.dirname(out))
      Dir.mktmpdir('.site-', File.dirname(out)) do |staging|
        site = File.join(staging, 'site')
        manifest = assemble(plan, out: site)
        FileUtils.rm_rf(out)
        File.rename(site, out)
        manifest
      end
    end

    def assemble(plan, out:)
      plan.entries.each { |entry| write(entry, out:) }
      File.binwrite(File.join(out, plan.names.fetch('disk')), plan.disk.content)
      index = render_index(File.read(plan.index), terminal: plan.names.fetch('terminal.js'),
                                                  source: Source.new(ref: plan.manifest.dig(:source, :ref)))
      File.write(File.join(out, 'index.html'), index)
      manifest = plan.manifest.merge(compressed_bytes: File.size(File.join(out, plan.names.fetch('image'))))
      File.write(File.join(out, MANIFEST), "#{JSON.pretty_generate(manifest)}\n")
      File.write(File.join(out, MARKER), "built by tools/build_site.rb\n")
      manifest
    end
    private_class_method :assemble

    def write(entry, out:)
      target = File.join(out, entry.path)
      FileUtils.mkdir_p(File.dirname(target))
      return FileUtils.cp(entry.source, target) unless entry.gzip

      Zlib::GzipWriter.open(target, Zlib::BEST_COMPRESSION) do |gz|
        gz.mtime = 0 # the same image gives the same bytes
        File.open(entry.source, 'rb') { |input| IO.copy_stream(input, gz) }
      end
    end
    private_class_method :write

    CONTENT_TYPES = {
      '.html' => 'text/html; charset=utf-8', '.css' => 'text/css', '.svg' => 'image/svg+xml',
      '.js' => 'text/javascript',
      '.mjs' => 'text/javascript', '.wasm' => 'application/wasm', '.json' => 'application/json',
      '.gz' => 'application/gzip', '.bin' => 'application/octet-stream'
    }.freeze

    # Maps each URL path to a file of the site directory, listed once at
    # start: a request names an entry of this table or gets 404, so no
    # request path ever reaches the file system. The MARKER is not served.
    def routes(dir)
      Dir.glob('**/*', base: dir).select { |path| path != MARKER && File.file?(File.join(dir, path)) }
         .to_h { |path| ["/#{path}", File.join(dir, path)] }
         .then { |table| table.merge('/' => table.fetch('/index.html')) }
    end

    # A minimal static server for viewing the site locally, bound to
    # 127.0.0.1 only. Runs until interrupted. It is a development tool: one
    # thread per connection, no limits on request size or time, so a client
    # on this machine can hang or exhaust it.
    def serve(dir:, port:)
      table = routes(dir)
      server = begin
        TCPServer.new('127.0.0.1', port)
      rescue SystemCallError => error
        raise Error, "cannot listen on 127.0.0.1:#{port}: #{error.message}"
      end
      puts "Site: http://127.0.0.1:#{port}/"
      loop { Thread.new(server.accept) { |client| answer(client, table) } }
    ensure
      server&.close
    end

    def answer(client, table)
      method, target = client.gets.to_s.b.split
      skip_headers(client)
      file = table[target.to_s.split('?').first] if %w[GET HEAD].include?(method)
      if file.nil?
        client.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        return
      end

      type = CONTENT_TYPES.fetch(File.extname(file), 'text/plain; charset=utf-8')
      client.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{File.size(file)}\r\n" \
                   "Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
      File.open(file, 'rb') { |input| IO.copy_stream(input, client) } if method == 'GET'
    rescue SystemCallError, IOError
      nil # the browser went away mid-response
    ensure
      client.close
    end
    private_class_method :answer

    # Reads the request's header lines up to the blank line that ends them.
    def skip_headers(client)
      loop do
        line = client.gets
        break if line.nil? || line.strip.empty?
      end
    end
    private_class_method :skip_headers
  end
end
