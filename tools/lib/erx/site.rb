# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'socket'
require 'tmpdir'
require 'zlib'
require_relative 'error'

module Erx
  # Assembles the static website in build/site from three inputs: the page
  # sources in site/, v64's build outputs (the emulator the page runs erXos
  # on), and an erXos boot image. None of the built files is checked in.
  #
  # The image is stored gzip-compressed under a name that carries its digest,
  # so a cache never serves a stale image, and boot.json tells the page its
  # name, sizes and SHA-256. The page decompresses it with
  # DecompressionStream, so the static host needs no Content-Encoding setup.
  module Site
    PAGE_FILES = %w[index.html style.css terminal.js].freeze
    # The v64 files the page loads, from its build directory, and the license
    # texts that must accompany them, from its checkout.
    V64_BUILD_FILES = %w[libv86.mjs v86-arm64.wasm].freeze
    V64_LICENSES = %w[LICENSE LICENSE.MIT].freeze
    MANIFEST = 'boot.json'
    # Marks a directory this step built; the server's route table skips it.
    MARKER = '.erx-site'
    # v64 is used unmodified: deps.lock pins its commit and Closure Compiler,
    # which its JavaScript build needs, and `tools/erx fetch` places them here.
    V64_SOURCE = 'build/third_party/v64/v64-87d26de'
    CLOSURE_JAR = 'build/third_party/closure-compiler/closure-compiler-v20210601.jar'
    V64_TARGETS = %w[build/libv86.mjs build/v86-arm64.wasm].freeze

    # One output file: where it goes under the site directory, where it comes
    # from, and whether it is stored gzip-compressed.
    Entry = Data.define(:path, :source, :gzip)
    Image = Data.define(:name, :bytes, :sha256)
    Plan = Data.define(:entries, :image)

    module_function

    # Builds v64's release bundle and ARM64 core in its fetched source tree
    # with v64's own Makefile. Needs Node with npm, clang with the wasm32
    # target, Rust with the wasm32-unknown-unknown target, and Java. `npm ci`
    # installs v64's build tools from its package-lock.json, from the npm
    # registry, and replaces any half-finished install; make then skips
    # Closure Compiler's download because CLOSURE names the pinned jar.
    def build_v64(root:)
      source = File.join(root, V64_SOURCE)
      closure = File.join(root, CLOSURE_JAR)
      missing = [source, closure].reject { |path| File.exist?(path) }
      unless missing.empty?
        raise Error, "missing #{missing.first}: run tools/erx fetch --source v64 and --source closure-compiler"
      end

      run(['npm', 'ci', '--no-audit', '--no-fund'], chdir: source)
      run(['make', '-C', source, "CLOSURE=#{closure}", *V64_TARGETS])
      source
    end

    def run(argv, chdir: Dir.pwd)
      system(*argv, chdir:, in: File::NULL, exception: false) or raise Error, "#{argv.first} failed: #{argv.join(' ')}"
    end
    private_class_method :run

    # The pure part: which files go where. Raises Erx::Error naming the first
    # missing input.
    def plan(root:, v64:, image:)
      page = PAGE_FILES.map { |name| Entry.new(path: name, source: File.join(root, 'site', name), gzip: false) }
      emulator = V64_BUILD_FILES.map { |name| Entry.new(path: "v64/#{name}", source: File.join(v64, 'build', name), gzip: false) }
      licenses = V64_LICENSES.map { |name| Entry.new(path: "v64/#{name}", source: File.join(v64, name), gzip: false) }
      missing = [*page, *emulator, *licenses].map(&:source).push(image).reject { |path| File.file?(path) }
      raise Error, "site input missing: #{missing.first}" unless missing.empty?

      digest = Digest::SHA256.file(image).hexdigest
      boot = Image.new(name: "image-#{digest[0, 16]}.boot.gz", bytes: File.size(image), sha256: digest)
      Plan.new(entries: [*page, *emulator, *licenses, Entry.new(path: boot.name, source: image, gzip: true)],
               image: boot)
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
      compressed = File.size(File.join(out, plan.image.name))
      emulator = V64_BUILD_FILES.sum { |name| File.size(File.join(out, 'v64', name)) }
      manifest = { image: plan.image.name, bytes: plan.image.bytes, compressed_bytes: compressed,
                   emulator_bytes: emulator, sha256: plan.image.sha256 }
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
      '.html' => 'text/html; charset=utf-8', '.css' => 'text/css', '.js' => 'text/javascript',
      '.mjs' => 'text/javascript', '.wasm' => 'application/wasm', '.json' => 'application/json',
      '.gz' => 'application/gzip'
    }.freeze

    # Maps each URL path to a file of the site directory, listed once at
    # start: a request names an entry of this table or gets 404, so no
    # request path ever reaches the file system.
    def routes(dir)
      Dir.glob('**/*', base: dir).select { |path| File.file?(File.join(dir, path)) }
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
