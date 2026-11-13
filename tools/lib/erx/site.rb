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
require_relative 'boot_partition'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'json_input'
require_relative 'medium_image'
require_relative 'site_v64'

module Erx
  # Assembles the static website in build/site from five inputs: the page
  # sources in site/, a v64 tree SiteV64 built (the emulator the page runs
  # erXos on, with its licence notices), an erXos boot image, the Raspberry
  # Pi 4's card with its build record (BootPartition), and the source both
  # were built from. None of the built files is checked in.
  #
  # It also makes the disk the page attaches to the machine as its virtio
  # block device, on the virtio-mmio slot where the QEMU harness attaches
  # its guest's: a boot medium laid out by abi/medium.txt whose windows are
  # blank but for the data partition's fresh littlefs volume (fresh_medium).
  # The medium is 1.2 GiB, but only its partition table and the volume's
  # first blocks hold bytes, so it is published as those bytes and the
  # extents they fill, and the page keeps it sparse.
  #
  # The image, the disk, terminal.js and v64's two files are stored under
  # names that carry their digests, and boot.json (fetched without the
  # cache's copy) and index.html name them, so a cache never serves a stale
  # file and files of two deployments never mix. The image is gzip-compressed; the
  # page decompresses it with DecompressionStream, so the static host needs
  # no Content-Encoding setup.
  #
  # The card is a download, gzip-compressed too: macOS, Linux and Windows
  # open gzip with what they ship, Raspberry Pi Imager writes it as it is,
  # and Ruby's zlib writes it without a tool the workflow would have to
  # install. Its build record is published beside it, once card_record finds
  # it is the card's, of the commit the page links with no changes, and
  # names no host path.
  #
  # The image and the card carry GPL-2.0 code, the stopgap kernel's and the
  # board's device tree, so the page links the erXos source they were built
  # from, a release tag or a commit, beside the console and the download
  # (docs/design.md, "Licences and notices").
  module Site
    PAGE_FILES = %w[index.html style.css favicon.svg terminal.js].freeze
    MANIFEST = 'boot.json'
    # Marks a directory this step built; the server's route table skips it.
    MARKER = '.erx-site'
    REPOSITORY = 'https://github.com/stass/erXos'
    TAG = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/
    COMMIT = /\A[0-9a-f]{40}\z/
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    # A card's build record is a few kilobytes; anything far larger is not one.
    MAX_CARD_RECORD = 1024 * 1024

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
    # the image's compressed_bytes and the card's compressed_bytes and
    # compressed_sha256, which only the written files give; card_record: the
    # card's build record as card_record checked it, which is what is
    # published, so no byte of the file goes out unchecked.
    Plan = Data.define(:entries, :index, :names, :disk, :manifest, :card_record)

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

    # The data partition's length on the page's disk: the layout's minimum
    # (128 MiB).
    def data_sectors = MediumImage.constant('data_sectors_min')

    # The disk the page attaches: a boot medium of data_sectors whose windows
    # are blank but for the data partition, which holds volume, the bytes of
    # a fresh littlefs volume of that partition (DataVolume.format). Making
    # the disk is the page's installation, the one step that formats /data,
    # since the guest's mount never does. erx_blk_table admits it. Only the
    # partition table's three records and the volume hold bytes.
    def fresh_medium(volume:)
      pieces = MediumImage.records(data_sectors:).merge(MediumImage.constant('data_start') => volume)
      disk(pieces:, capacity: MediumImage.sectors(data_sectors:) * SECTOR_BYTES)
    end

    # The card's build record, parsed from the bytes of a BootPartition
    # receipt, once it names sha256 as its card's, names source's commit as
    # the one the card was built from with no changes, and holds no absolute
    # path (BootPartition.check_record). The page links source as the card's,
    # so a record of another card or commit, of a changed tree, of a tree
    # that was no checkout, or one that would publish a host's paths, is
    # refused; so is a tag as source, which the record's commit cannot be
    # checked against here (the workflow resolves its tag to the commit).
    def card_record(bytes, sha256:, source:)
      unless COMMIT.match?(source.ref)
        raise Error, "the card's source must be given as its 40-hex commit, which its build record names, not #{source.ref}"
      end

      record = JsonInput.parse(bytes, max_bytes: MAX_CARD_RECORD, label: "the card's build record")
      artifact = { 'path' => BootPartition::IMAGE, 'sha256' => sha256 }
      unless record.is_a?(Hash) && record['artifact'] == artifact
        raise Error, "the card's build record is not of this card, #{BootPartition::IMAGE} with SHA-256 #{sha256}"
      end
      unless record['source'] == { 'commit' => source.ref, 'dirty' => false }
        raise Error, "the card's build record does not name #{source.ref}, with no changes, as the source it was built from"
      end

      BootPartition.check_record(record)
    end

    # Reads the inputs' sizes and digests and decides which file goes where.
    # Raises Erx::Error naming the first missing input, or for a card whose
    # build record is not its own or not of source (card_record). card and
    # card_record are both paths or both nil; nil is a build without the
    # Raspberry Pi 4's card, for a local preview (tools/build_site.rb
    # --no-card), whose page has no card section and whose boot.json has no
    # card entry.
    def inventory(root:, v64:, image:, card:, card_record:, source:, disk:)
      raise Error, 'the card and its build record are given both or neither' unless card.nil? == card_record.nil?

      page = PAGE_FILES.to_h { |name| [name, File.join(root, 'site', name)] }
      emulator = SiteV64::TARGETS.transform_values { |path| File.join(v64, path) }
      notices = SiteV64::NOTICES.transform_values { |path| File.join(v64, path) }
      missing = [*page.values, *emulator.values, *notices.values, image, card, card_record].compact.reject { |path| File.file?(path) }
      raise Error, "site input missing: #{missing.first}" unless missing.empty?

      digest = ->(path) { Digest::SHA256.file(path).hexdigest }
      image_sha256 = digest.(image)
      disk_sha256 = Digest::SHA256.hexdigest(disk.content)
      card_sha256 = card && digest.(card)
      record = card && card_record(BoundedFile.read(card_record, maximum: MAX_CARD_RECORD), sha256: card_sha256, source:)
      names = { 'terminal.js' => digest_name('terminal.js', digest.(page.fetch('terminal.js'))),
                'image' => "image-#{image_sha256[0, 16]}.boot.gz", 'disk' => "disk-#{disk_sha256[0, 16]}.bin" }
              .merge(card ? { 'card' => "sdcard-#{card_sha256[0, 16]}.img.gz",
                              'card_record' => "sdcard-#{card_sha256[0, 16]}.img.receipt.json" } : {})
              .merge(emulator.to_h { |name, path| [name, "v64/#{digest_name(name, digest.(path))}"] })
      entries = [Entry.new(path: 'style.css', source: page.fetch('style.css'), gzip: false),
                 Entry.new(path: 'favicon.svg', source: page.fetch('favicon.svg'), gzip: false),
                 Entry.new(path: names.fetch('terminal.js'), source: page.fetch('terminal.js'), gzip: false),
                 *emulator.map { |name, path| Entry.new(path: names.fetch(name), source: path, gzip: false) },
                 *notices.map { |name, path| Entry.new(path: "v64/#{name}", source: path, gzip: false) },
                 Entry.new(path: names.fetch('image'), source: image, gzip: true),
                 *(Entry.new(path: names.fetch('card'), source: card, gzip: true) if card)]
      manifest = { image: names.fetch('image'), bytes: File.size(image), sha256: image_sha256,
                   emulator: { module: names.fetch('libv86.mjs'), wasm: names.fetch('v86-arm64.wasm'),
                               bytes: emulator.values.sum { |path| File.size(path) } },
                   disk: { file: names.fetch('disk'), bytes: disk.content.bytesize, sha256: disk_sha256,
                           capacity: disk.capacity, extents: disk.extents },
                   source: { ref: source.ref, url: source.url } }
      if card
        manifest[:card] = { file: names.fetch('card'), bytes: File.size(card), sha256: card_sha256,
                            record: names.fetch('card_record') }
      end
      Plan.new(entries:, index: page.fetch('index.html'), names:, disk:, manifest:, card_record: record)
    end

    # What index.html wraps its card section in: kept, without the markers,
    # for a build with a card and removed with it for one without.
    CARD_BLOCK = %r{<!--card-->(.*?)<!--/card-->\n?}m

    # index.html with its {{name}} placeholders filled in. card is boot.json's
    # card entry, or nil for a build without a card, which has no card
    # placeholder to fill. Every value is HTML-escaped; an unknown
    # placeholder raises, so a card placeholder outside the card section
    # fails a build without a card instead of reaching the page.
    def render_index(template, terminal:, source:, card:)
      values = { 'terminal_js' => terminal, 'source_url' => source.url, 'source_label' => source.label }
      values.merge!('card_file' => card.fetch(:file), 'card_record' => card.fetch(:record),
                    'card_sha256' => card.fetch(:sha256), 'card_download_sha256' => card.fetch(:compressed_sha256)) if card
      template = template.gsub(CARD_BLOCK) { card ? Regexp.last_match(1) : '' }
      template.gsub(/\{\{([a-z][a-z0-9_]*)\}\}/) do
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
      card = plan.manifest[:card] && publish_card(plan, out:)
      manifest = plan.manifest.merge(compressed_bytes: File.size(File.join(out, plan.names.fetch('image'))))
      manifest[:card] = card if card
      index = render_index(File.read(plan.index), terminal: plan.names.fetch('terminal.js'),
                                                  source: Source.new(ref: plan.manifest.dig(:source, :ref)), card:)
      File.write(File.join(out, 'index.html'), index)
      File.write(File.join(out, MANIFEST), "#{JSON.pretty_generate(manifest)}\n")
      File.write(File.join(out, MARKER), "built by tools/build_site.rb\n")
      manifest
    end
    private_class_method :assemble

    # The card's record beside its download, and the card's manifest entry
    # with the download's size and digest.
    def publish_card(plan, out:)
      File.write(File.join(out, plan.names.fetch('card_record')), "#{JSON.pretty_generate(plan.card_record)}\n")
      download = File.join(out, plan.names.fetch('card'))
      plan.manifest.fetch(:card).merge(compressed_bytes: File.size(download),
                                       compressed_sha256: Digest::SHA256.file(download).hexdigest)
    end
    private_class_method :publish_card

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
