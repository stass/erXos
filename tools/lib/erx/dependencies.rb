# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'uri'
require 'digest'
require 'find'
require 'tmpdir'
require_relative 'runner'
require_relative 'sources'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'bounded_file'
require_relative 'dependency_status'

module Erx
  module DependencySchema
    COMMON_FIELDS = %w[id kind version sha256 license status].freeze
    # The hosts a zip source can name, each with the Ruby platforms it covers. A zip
    # source is a prebuilt program for one host (Playwright's Chromium), fetched only
    # on that host, or data for every host ('any': Freedoom's release archive).
    HOSTS = { 'darwin-arm64' => /\A(?:arm64|aarch64)-darwin/, 'any' => /./ }.freeze
    # A file source may also pin what it encodes, an image inside a test program, by
    # the decoded bytes' SHA-256 and size, both or neither: the reader that decodes it
    # checks them, and decompresses no more than decoded_bytes. The fetch step checks
    # only the file's own sha256.
    DECODED_FIELDS = %w[decoded_sha256 decoded_bytes].freeze
    MAX_DECODED_BYTES = 1 << 30
    # The platforms an OCI image source can pin, each with the architecture a Docker
    # engine of that platform reports (docker info reports the machine name, as
    # uname -m prints it).
    OCI_PLATFORMS = { 'linux/arm64' => 'aarch64', 'linux/amd64' => 'x86_64' }.freeze
    module_function

    def parse(bytes)
      value = JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'dependency lock')
      unless value.is_a?(Hash) && value.keys.sort == %w[sources version] &&
             value.fetch('version') == 1 && value.fetch('sources').is_a?(Array)
        raise Error, 'deps.lock must contain version 1 and a sources array'
      end
      sources = value.fetch('sources')
      raise Error, 'deps.lock has no sources' if sources.empty?

      sources.each { |source| validate_source(source) }
      ids = sources.map { |source| source.fetch('id') }
      raise Error, 'duplicate source id in deps.lock' unless ids.uniq == ids

      sources.map { |source| source.transform_values(&:freeze).freeze }.freeze
    end

    def validate_source(source)
      raise Error, 'invalid source declaration' unless source.is_a?(Hash)
      case source['kind']
      when 'tar'
        # members, when given, names what of directory is extracted: an archive whose
        # whole tree exceeds Sources' bounds pins the parts a build reads.
        fields = COMMON_FIELDS + %w[url directory] + (source.key?('members') ? %w[members] : [])
        member = 'directory'
      when 'zip'
        fields = COMMON_FIELDS + %w[url directory host]
        member = 'directory'
      when 'git'
        fields = COMMON_FIELDS + %w[url directory commit]
        member = 'directory'
      when 'file'
        fields = COMMON_FIELDS + %w[url filename] + (DECODED_FIELDS.any? { |field| source.key?(field) } ? DECODED_FIELDS : [])
        member = 'filename'
      when 'oci'
        fields = COMMON_FIELDS + %w[repository platform config_sha256]
        member = nil
      else
        raise Error, 'invalid source kind'
      end
      unless source.keys.sort == fields.sort &&
             source.except('decoded_bytes').values.all? { |value| value.is_a?(String) && !value.empty? }
        raise Error, 'invalid source fields in deps.lock'
      end
      ['id', member].compact.each do |field|
        next if source.fetch('kind') == 'tar' && field == 'directory' && source.fetch(field) == '.'
        unless /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/.match?(source.fetch(field))
          raise Error, "invalid source #{field}"
        end
      end
      if source.key?('members') && (source.fetch('directory') == '.' || !Sources.valid_members?(source.fetch('members')))
        raise Error, 'invalid source members'
      end
      raise Error, 'invalid source SHA-256' unless /\A[0-9a-f]{64}\z/.match?(source.fetch('sha256'))
      if source.key?('decoded_sha256') &&
         !(/\A[0-9a-f]{64}\z/.match?(source.fetch('decoded_sha256')) &&
           source.fetch('decoded_bytes').is_a?(Integer) && source.fetch('decoded_bytes').between?(1, MAX_DECODED_BYTES))
        raise Error, 'invalid decoded image pin'
      end
      raise Error, 'invalid source commit' if source.fetch('kind') == 'git' && !/\A[0-9a-f]{40}\z/.match?(source.fetch('commit'))
      raise Error, 'invalid dependency status' unless DependencyStatus::ALL.include?(source.fetch('status'))
      raise Error, 'invalid source host' if source.fetch('kind') == 'zip' && !HOSTS.key?(source.fetch('host'))

      if source.fetch('kind') == 'oci'
        unless /\A[a-z0-9][a-z0-9.:-]*(?:\/[a-z0-9][a-z0-9._-]*)+\z/.match?(source.fetch('repository')) &&
               OCI_PLATFORMS.key?(source.fetch('platform')) &&
               /\A[0-9a-f]{64}\z/.match?(source.fetch('config_sha256'))
          raise Error, 'invalid pinned OCI image'
        end
        return
      end

      url = URI.parse(source.fetch('url'))
      unless url.is_a?(URI::HTTPS) && url.host && !url.userinfo && !url.fragment
        raise Error, 'dependency URL must be HTTPS without credentials or fragment'
      end
    rescue URI::InvalidURIError
      raise Error, 'invalid dependency URL'
    end
    private_class_method :validate_source

    # Whether source is fetched on a host of platform (a RUBY_PLATFORM): every
    # source but a zip for another host.
    def for_host?(source, platform:) = source.fetch('kind') != 'zip' || HOSTS.fetch(source.fetch('host')).match?(platform)
  end

  class Dependencies
    MAX_ARCHIVE_BYTES = Sources::MAX_ARCHIVE_BYTES
    # The markers fetch writes at the top of build/third_party/ID once the tree
    # below is extracted: the pin it extracted, and the digest of what it extracted.
    RECORD = '.source.json'
    TREE_DIGEST = '.tree.sha256'
    # The variables that would redirect a docker command named by its --host endpoint,
    # unset for each such command.
    DOCKER_ENVIRONMENT = { 'DOCKER_CONTEXT' => nil, 'DOCKER_HOST' => nil, 'DOCKER_TLS_VERIFY' => nil,
                           'DOCKER_CERT_PATH' => nil, 'DOCKER_API_VERSION' => nil }.freeze
    # sources are deps.lock's sources this host uses, which every caller walks;
    # elsewhere the programs it pins for other hosts, which no step here fetches.
    attr_reader :sources, :elsewhere

    def initialize(root:, runner:, lock_path: File.join(root, 'deps.lock'), tar_program: 'tar', docker_context: nil,
                   platform: RUBY_PLATFORM)
      @root = File.expand_path(root)
      @runner = runner
      @tar_program = tar_program
      @docker_context = docker_context
      @sources, @elsewhere = DependencySchema.parse(File.binread(lock_path))
                                             .partition { |source| DependencySchema.for_host?(source, platform: platform) }
                                             .map(&:freeze)
    end

    # Fetches every source this host uses, or the sources source_ids names. A cache is
    # another checkout's build/downloads: the archives come from it, never
    # from the network, and each is verified against its pin. With a cache an
    # OCI image is not fetched: the Docker cache holds it, and only its own
    # fetch contacts a registry; naming one with a cache is refused.
    def fetch(cache: nil, source_ids: nil)
      if cache && !File.directory?(cache)
        raise Error, "source cache is not a directory (it is another checkout's build/downloads): #{cache}"
      end

      # Every id is resolved before anything is fetched, so an unknown one fetches nothing.
      selected = source_ids ? source_ids.map { |id| pinned(id) } : sources
      images = cache ? selected.select { |source| oci?(source) } : []
      raise Error, 'OCI images use the Docker cache; fetch them explicitly without --cache' if source_ids && !images.empty?

      # Each source is fetched on its own, so one that fails leaves the others
      # fetched; the failures are reported together at the end, each after its id.
      failures = (selected - images).filter_map { |source| failure_of(source, cache: cache) }
      raise Error, failures.join('; ') unless failures.empty?
    end

    # The OCI images among the sources this host uses, which only their own fetch obtains.
    def images = sources.select { |source| oci?(source) }

    # Whether build/third_party/ID holds what fetch published for deps.lock's
    # pin of ID: its provenance record equals the pin's entry.
    def fetched?(id) = recorded?(pinned(id))

    # The unpacked tree of a tar, zip or git source as fetch published it, for a
    # build that compiles from it. Raises with the command that fetches it
    # when the source is absent or holds another pin.
    def fetched_tree(id)
      source = pinned(id)
      raise Error, "#{id} is a #{source.fetch('kind')} source, not a tree" unless %w[tar zip git].include?(source.fetch('kind'))

      destination = destination_of(source)
      raise Error, "source #{id} is not fetched; #{fetch_command(id)}" unless File.exist?(destination) || File.symlink?(destination)
      raise Error, stale(id) unless recorded?(source)

      tree = source.fetch('directory') == '.' ? destination : File.join(destination, source.fetch('directory'))
      raise Error, stale(id) unless File.directory?(tree) && !File.symlink?(tree)

      tree
    end

    # The file of a file source as fetch published it, for a build that reads
    # it. Raises with the command that fetches it when the source is absent
    # or holds another pin.
    def fetched_file(id)
      source = pinned(id)
      raise Error, "#{id} is a #{source.fetch('kind')} source, not a file" unless source.fetch('kind') == 'file'
      raise Error, "source #{id} is not fetched; #{fetch_command(id)}" unless File.exist?(destination_of(source))
      raise Error, stale(id) unless recorded?(source)

      file = File.join(destination_of(source), source.fetch('filename'))
      raise Error, stale(id) unless File.file?(file) && !File.symlink?(file)

      file
    end

    # Where fetch keeps source id's verified download, by its kind's file name.
    def archive_path_of(id) = archive_path(pinned(id))

    def archive_for(id)
      source = sources.find { |entry| entry.fetch('id') == id }
      raise Error, "unknown source: #{id}" unless source
      raise Error, 'OCI image is not a file archive' if source.fetch('kind') == 'oci'

      archive = archive_path(source)
      raise Error, "missing source #{id}; run make fetch" unless File.file?(archive)
      verify(source, archive: archive)
      [source, archive].freeze
    end

    # This supplies identity only. Execution must inspect the cached image and
    # must never trigger a pull; the fetch entry point alone contacts registries.
    def image_for(id)
      source = sources.find { |entry| entry.fetch('id') == id }
      raise Error, "unknown image source: #{id}" unless source && source.fetch('kind') == 'oci'
      source.merge('reference' => "#{source.fetch('repository')}@sha256:#{source.fetch('sha256')}",
                   'manifest_sha256' => source.fetch('sha256')).transform_values(&:freeze).freeze
    end

    # The Docker context (the given one, else the CLI's current one) and its endpoint,
    # refused unless that endpoint is an existing local UNIX socket: what lets a caller
    # name the engine by its socket (`docker --host`), with DOCKER_ENVIRONMENT, so no
    # TCP or SSH endpoint, nor a variable of the operator's, chooses another.
    def local_docker_connection
      context = @docker_context
      unless context
        command = @runner.run(['docker', 'context', 'show'], name: 'docker-context', deadline: 10)
        context = (File.binread(command.fetch('log'), 256) || '').strip
      end
      unless context.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(context)
        raise Error, 'invalid Docker context name'
      end
      command = @runner.run(['docker', 'context', 'inspect', context, '--format',
                            '{{(index .Endpoints "docker").Host}}'], name: 'docker-endpoint', deadline: 10)
      endpoint = (File.binread(command.fetch('log'), 4096) || '').strip
      uri = URI.parse(endpoint)
      unless uri.scheme == 'unix' && (uri.host.nil? || uri.host.empty?) &&
             uri.userinfo.nil? && uri.opaque.nil? && uri.port.nil? &&
             uri.query.nil? && uri.fragment.nil? && uri.path.is_a?(String) &&
             uri.path.start_with?('/') && File.socket?(uri.path)
        raise Error, "Docker context #{context} is not an explicit local UNIX socket endpoint"
      end
      canonical = "unix://#{File.realpath(uri.path)}".freeze
      { 'context' => context.freeze, 'endpoint' => canonical }.freeze
    rescue URI::InvalidURIError
      raise Error, 'invalid Docker endpoint URI'
    end

    private

    def fetch_image(source)
      connection = local_docker_connection
      prefix = ['docker', '--host', connection.fetch('endpoint')]
      environment = DOCKER_ENVIRONMENT
      reference = "#{source.fetch('repository')}@sha256:#{source.fetch('sha256')}"
      @runner.run(prefix + ['pull', '--platform', source.fetch('platform'), reference],
                  name: "fetch-#{source.fetch('id')}", deadline: 900, env: environment)
      command = @runner.run(prefix + ['image', 'inspect', reference,
                                     '--format', '{{json .}}'],
                            name: 'verify-oci-image', deadline: 30, env: environment)
      bytes = File.binread(command.fetch('log'), 1024 * 1024 + 1) || ''.b
      raise Error, 'OCI image identity exceeds reader bound' if bytes.bytesize > 1024 * 1024
      value = JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'OCI image identity')
      unless value.is_a?(Hash) && %w[Os Architecture Id].all? { |field| value[field].is_a?(String) } &&
             value['RepoDigests'].is_a?(Array) && value['RepoDigests'].all? { |digest| digest.is_a?(String) }
        raise Error, 'invalid OCI image identity fields'
      end
      platform = "#{value.fetch('Os')}/#{value.fetch('Architecture')}"
      digests = value.fetch('RepoDigests')
      manifest_id = "sha256:#{source.fetch('sha256')}"
      config_id = "sha256:#{source.fetch('config_sha256')}"
      descriptor = value['Descriptor']
      descriptor_matches = descriptor.nil? || (descriptor.is_a?(Hash) && descriptor['digest'] == manifest_id)
      # Engines identify cached images by either the selected manifest or its
      # configuration. The pinned manifest binds that configuration and layers.
      unless platform == source.fetch('platform') &&
             [manifest_id, config_id].include?(value.fetch('Id')) && descriptor_matches &&
             digests.is_a?(Array) && digests.any? { |digest| digest.end_with?("@sha256:#{source.fetch('sha256')}") }
        raise Error, 'cached OCI image does not match pinned platform and digests'
      end
    rescue KeyError, TypeError => error
      raise Error, "invalid OCI image identity: #{error.message}"
    end

    def archive_path(source)
      suffix = case source.fetch('kind')
               when 'tar', 'git' then '.tar.gz'
               when 'zip' then '.zip'
               else File.extname(source.fetch('filename'))
               end
      parent = OutputDirectory.check(root: @root, path: File.join(@root, 'build/downloads'))
      path = File.join(parent, "#{source.fetch('id')}-#{source.fetch('sha256')}#{suffix}")
      raise Error, 'downloaded source archive must not be a symbolic link' if File.symlink?(path)
      path
    end

    def obtain(source, archive:, cache:)
      return if File.file?(archive)

      OutputDirectory.prepare(root: @root, path: File.dirname(archive))
      Dir.mktmpdir('.download-', File.dirname(archive)) do |directory|
        temporary = File.join(directory, 'source.tar.gz')
        if cache
          cached = File.join(cache, File.basename(archive))
          raise Error, "source not found in source cache: #{cached}" unless File.file?(cached)
          copy_bounded(cached, destination: temporary)
        elsif source.fetch('kind') == 'git'
          export_commit(source, directory: directory, archive: temporary)
        else
          @runner.run(['curl', '--disable', '--fail', '--location', '--silent', '--show-error',
                       '--proto', '=https', '--proto-redir', '=https',
                       '--connect-timeout', '20', '--max-time', '180',
                       '--max-filesize', MAX_ARCHIVE_BYTES.to_s,
                       '--output', temporary, source.fetch('url')],
                      name: "fetch-#{source.fetch('id')}", deadline: 200)
        end
        verify(source, archive: temporary)
        File.rename(temporary, archive)
      end
    end

    # A source whose host serves no stable archive: the pinned commit, as git's own
    # uncompressed tar of it, which the pinned hash then holds like any download's.
    def export_commit(source, directory:, archive:)
      clone = File.join(directory, 'clone')
      @runner.run(['git', '-c', 'protocol.allow=never', '-c', 'protocol.https.allow=always', 'clone', '--quiet', '--bare',
                   source.fetch('url'), clone], name: "fetch-#{source.fetch('id')}", deadline: 200)
      @runner.run(['git', '-C', clone, 'archive', '--format=tar', "--prefix=#{source.fetch('directory')}/",
                   '--output', archive, source.fetch('commit')], name: "export-#{source.fetch('id')}", deadline: 60)
    end

    def copy_bounded(source, destination:)
      File.open(source, File::RDONLY | File::NONBLOCK) do |input|
        unless input.stat.file? && input.size <= MAX_ARCHIVE_BYTES
          raise Error, 'source input must be a bounded regular file'
        end
        input.binmode
        File.open(destination, 'wb') do |output|
          written = IO.copy_stream(input, output, MAX_ARCHIVE_BYTES + 1)
          raise Error, 'compressed source archive exceeds budget' if written > MAX_ARCHIVE_BYTES
        end
      end
    end

    public def pinned(id)
      found = sources.find { |source| source.fetch('id') == id }
      return found if found

      other = elsewhere.find { |source| source.fetch('id') == id }
      raise Error, other ? "#{id} is a program for #{other.fetch('host')} only" : "deps.lock pins no source #{id}"
    end

    def fetch_command(id) = "run `ruby tools/erx fetch --source #{id}`"

    def stale(id) = "build/third_party/#{id} does not hold deps.lock's pin of #{id}; remove it and #{fetch_command(id)}"

    # What went wrong fetching source, or nil when it was fetched.
    def failure_of(source, cache:)
      fetch_source(source, cache: cache)
      nil
    rescue Error, SystemCallError => e
      "#{source.fetch('id')}: #{e.message}"
    end

    def oci?(source) = source.fetch('kind') == 'oci'

    def fetch_source(source, cache:)
      return fetch_image(source) if oci?(source)

      archive = archive_path(source)
      obtain(source, archive: archive, cache: cache)
      verify(source, archive: archive)
      publish(source, archive: archive)
    end

    # The text of the marker fetch wrote at the top of build/third_party/ID,
    # or nil when there is none, it is a link, or it is not a small file.
    def marker_text(source, name)
      destination = destination_of(source)
      marker = File.join(destination, name)
      return nil unless File.directory?(destination) && !File.symlink?(destination) &&
                        File.file?(marker) && !File.symlink?(marker)

      BoundedFile.read(marker, maximum: 65_536)
    rescue Error
      nil
    end

    # A record another fetch wrote, of another pin or of an older deps.lock
    # schema, is not this pin's: there is no reading of old records.
    def recorded?(source)
      text = marker_text(source, RECORD)
      !text.nil? && JsonInput.parse(text, max_bytes: 65_536, label: 'source download record') == source
    rescue JsonInput::Unsupported
      raise
    rescue Error
      false
    end

    # Whether a recorded build/third_party/ID is unchanged since fetch extracted
    # it, by the code extracting today: what is there now has the digest fetch
    # wrote beside the record then. The digest is not keyed, so it catches
    # accidental change and changed extraction code, not a user who rewrites
    # the tree and the digest together. A tree the walk cannot read is not.
    def intact?(source)
      marker_text(source, TREE_DIGEST) == "#{tree_digest(destination_of(source))}\n"
    rescue SystemCallError
      false
    end

    def destination_of(source) = File.join(@root, 'build/third_party', source.fetch('id'))

    # The code that extracts a tree and writes its markers. A change to it
    # changes every tree's digest, so fetch extracts every tree again by it.
    def extractor_digest
      @extractor_digest ||= [Sources.method(:unpack), method(:publish)]
                            .map { |code| Digest::SHA256.file(code.source_location.first).hexdigest }.join(',')
    end

    # The SHA-256 of the extracting code and of every entry below top but the
    # two markers at its top: each entry's path relative to top, its kind, a
    # file's or directory's permission bits, and a file's contents or a link's
    # target, in path order. It names no absolute path, inode or time, so a
    # tree copied or moved elsewhere keeps its digest. Links are read, never
    # followed, and an entry the walk cannot read fails it.
    def tree_digest(top)
      names = Find.find(top, ignore_error: false).drop(1).map { |path| path.delete_prefix("#{top}/") }
      start = Digest::SHA256.new << "#{extractor_digest}\0"
      (names - [RECORD, TREE_DIGEST]).sort.each_with_object(start) do |name, digest|
        path = File.join(top, name)
        stat = File.lstat(path)
        bits, content = case stat.ftype
                        when 'file' then [stat.mode & 0o777, Digest::SHA256.file(path).hexdigest]
                        when 'directory' then [stat.mode & 0o777, '']
                        when 'link' then [0, File.readlink(path)]
                        else [0, '']
                        end
        # No field holds a NUL, so ending each with one keeps entries apart.
        digest << [name, stat.ftype, bits.to_s(8), content].map { |field| "#{field}\0" }.join
      end.hexdigest
    end

    def verify(source, archive:)
      unless Digest::SHA256.hexdigest(BoundedFile.read(archive, maximum: MAX_ARCHIVE_BYTES)) == source.fetch('sha256')
        raise Error, "source SHA-256 mismatch: #{source.fetch('id')}"
      end
    end

    # Extracts the verified archive to build/third_party/ID, unless the tree
    # there is already the pin's and intact, wherever it was extracted.
    def publish(source, archive:)
      destination = destination_of(source)
      parent = File.dirname(destination)
      OutputDirectory.prepare(root: @root, path: parent)
      raise Error, "source destination is a symlink: #{destination}" if File.symlink?(destination)
      raise Error, stale(source.fetch('id')) if File.exist?(destination) && !recorded?(source)
      return if intact?(source)

      Dir.mktmpdir('.source-', parent) do |temporary|
        extracted = File.join(temporary, 'tree')
        # tar is bsdtar on macOS and FreeBSD, and reads a zip as it reads a tar; a host whose
        # tar cannot read a zip refuses the source in Sources.unpack.
        if %w[tar zip git].include?(source.fetch('kind'))
          selected = extracted
          if source.fetch('directory') != '.'
            Dir.mkdir(extracted)
            selected = File.join(extracted, source.fetch('directory'))
          end
          Sources.unpack(archive: archive, sha256: source.fetch('sha256'),
                         destination: selected, owner_root: temporary,
                         source_directory: source.fetch('directory'), runner: @runner, tar_program: @tar_program,
                         members: source.fetch('members', '').split)
        else
          Dir.mkdir(extracted)
          file = File.join(extracted, source.fetch('filename'))
          copy_bounded(archive, destination: file)
          verify(source, archive: file)
        end
        markers = [RECORD, TREE_DIGEST].map { |name| File.join(extracted, name) }
        if markers.any? { |marker| File.exist?(marker) || File.symlink?(marker) }
          raise Error, 'source archive conflicts with its provenance marker'
        end
        File.write(File.join(extracted, TREE_DIGEST), "#{tree_digest(extracted)}\n")
        File.write(File.join(extracted, RECORD), JSON.pretty_generate(source) + "\n")
        # The extraction is disposable derived state. Preserve the previous
        # tree until the replacement is fully prepared; recover on publication
        # failure, and remove the old tree only after successful publication.
        previous = File.join(temporary, 'previous')
        File.rename(destination, previous) if File.exist?(destination)
        begin
          File.rename(extracted, destination)
        rescue SystemCallError
          File.rename(previous, destination) if File.exist?(previous)
          raise
        end
      end
    end

  end
end
