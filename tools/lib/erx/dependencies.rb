# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'uri'
require 'digest'
require 'tmpdir'
require_relative 'runner'
require_relative 'sources'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'bounded_file'

module Erx
  module DependencySchema
    COMMON_FIELDS = %w[id kind version sha256 license status].freeze
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
      when 'git'
        fields = COMMON_FIELDS + %w[url directory commit]
        member = 'directory'
      when 'file'
        fields = COMMON_FIELDS + %w[url filename]
        member = 'filename'
      when 'oci'
        fields = COMMON_FIELDS + %w[repository platform config_sha256]
        member = nil
      else
        raise Error, 'invalid source kind'
      end
      unless source.keys.sort == fields.sort &&
             source.values.all? { |value| value.is_a?(String) && !value.empty? }
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
      raise Error, 'invalid source commit' if source.fetch('kind') == 'git' && !/\A[0-9a-f]{40}\z/.match?(source.fetch('commit'))
      raise Error, 'invalid dependency status' unless %w[permanent stopgap].include?(source.fetch('status'))

      if source.fetch('kind') == 'oci'
        unless /\A[a-z0-9][a-z0-9.:-]*(?:\/[a-z0-9][a-z0-9._-]*)+\z/.match?(source.fetch('repository')) &&
               %w[linux/arm64 linux/amd64].include?(source.fetch('platform')) &&
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
  end

  class Dependencies
    MAX_ARCHIVE_BYTES = Sources::MAX_ARCHIVE_BYTES
    attr_reader :sources

    def initialize(root:, runner:, lock_path: File.join(root, 'deps.lock'), tar_program: 'tar', docker_context: nil)
      @root = File.expand_path(root)
      @runner = runner
      @tar_program = tar_program
      @docker_context = docker_context
      @sources = DependencySchema.parse(File.binread(lock_path))
    end

    def fetch(cache: nil, source_id: nil)
      selected = source_id ? sources.select { |source| source.fetch('id') == source_id } : sources
      raise Error, "unknown source: #{source_id}" if selected.empty?
      if cache && selected.any? { |source| source.fetch('kind') == 'oci' }
        raise Error, 'OCI images use the Docker cache; fetch them explicitly without --cache'
      end
      # Each source is fetched on its own, so one that fails leaves the others
      # fetched; the failures are reported together at the end, each after its id.
      failures = selected.filter_map { |source| failure_of(source, cache: cache) }
      raise Error, failures.join('; ') unless failures.empty?
    end

    # Whether build/third_party/ID holds what fetch published for deps.lock's
    # pin of ID: its provenance record equals the pin's entry.
    def fetched?(id) = recorded?(pinned(id))

    # The unpacked tree of a tar or git source as fetch published it, for a
    # build that compiles from it. Raises with the command that fetches it
    # when the source is absent or holds another pin.
    def fetched_tree(id)
      source = pinned(id)
      raise Error, "#{id} is a #{source.fetch('kind')} source, not a tree" unless %w[tar git].include?(source.fetch('kind'))

      destination = File.join(@root, 'build/third_party', id)
      raise Error, "source #{id} is not fetched; #{fetch_command(id)}" unless File.exist?(destination) || File.symlink?(destination)
      raise Error, stale(id) unless recorded?(source)

      tree = source.fetch('directory') == '.' ? destination : File.join(destination, source.fetch('directory'))
      raise Error, stale(id) unless File.directory?(tree) && !File.symlink?(tree)

      tree
    end

    # Takes a source archive from another checkout's downloads directory, but
    # only if its bytes match the pinned SHA-256; nothing unverified is kept.
    # An archive already present is left alone.
    def adopt(source_id, from:)
      source = sources.find { |entry| entry.fetch('id') == source_id }
      raise Error, "unknown source: #{source_id}" unless source && source.fetch('kind') != 'oci'

      archive = archive_path(source)
      return archive if File.file?(archive)

      OutputDirectory.prepare(root: @root, path: File.dirname(archive))
      Dir.mktmpdir('.adopt-', File.dirname(archive)) do |directory|
        temporary = File.join(directory, 'source')
        copy_bounded(from, destination: temporary)
        verify(source, archive: temporary)
        File.rename(temporary, archive)
      end
      archive
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

    private

    def fetch_image(source)
      connection = local_docker_connection
      prefix = ['docker', '--host', connection.fetch('endpoint')]
      environment = { 'DOCKER_CONTEXT' => nil, 'DOCKER_HOST' => nil,
                      'DOCKER_TLS_VERIFY' => nil, 'DOCKER_CERT_PATH' => nil,
                      'DOCKER_API_VERSION' => nil }
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
        raise Error, 'oracle fetch requires an explicit local UNIX Docker endpoint'
      end
      canonical = "unix://#{File.realpath(uri.path)}".freeze
      { 'context' => context.freeze, 'endpoint' => canonical }.freeze
    rescue URI::InvalidURIError
      raise Error, 'invalid Docker endpoint URI'
    end

    def archive_path(source)
      suffix = %w[tar git].include?(source.fetch('kind')) ? '.tar.gz' : File.extname(source.fetch('filename'))
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
          cached = File.join(cache, File.basename(URI.parse(source.fetch('url')).path))
          raise Error, "source not found in explicit cache: #{cached}" unless File.file?(cached)
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

    def pinned(id)
      sources.find { |source| source.fetch('id') == id } or raise Error, "deps.lock pins no source #{id}"
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

    def fetch_source(source, cache:)
      return fetch_image(source) if source.fetch('kind') == 'oci'

      archive = archive_path(source)
      obtain(source, archive: archive, cache: cache)
      verify(source, archive: archive)
      publish(source, archive: archive)
    end

    # A record another fetch wrote, of another pin or of an older deps.lock
    # schema, is not this pin's: there is no reading of old records.
    def recorded?(source)
      destination = File.join(@root, 'build/third_party', source.fetch('id'))
      marker = File.join(destination, '.source.json')
      return false unless File.directory?(destination) && !File.symlink?(destination) &&
                          File.file?(marker) && !File.symlink?(marker)

      JsonInput.parse(BoundedFile.read(marker, maximum: 65_536), max_bytes: 65_536,
                      label: 'source download record') == source
    rescue JsonInput::Unsupported
      raise
    rescue Error
      false
    end

    def verify(source, archive:)
      unless Digest::SHA256.hexdigest(BoundedFile.read(archive, maximum: MAX_ARCHIVE_BYTES)) == source.fetch('sha256')
        raise Error, "source SHA-256 mismatch: #{source.fetch('id')}"
      end
    end

    def publish(source, archive:)
      parent = File.join(@root, 'build/third_party')
      OutputDirectory.prepare(root: @root, path: parent)
      destination = File.join(parent, source.fetch('id'))
      raise Error, "source destination is a symlink: #{destination}" if File.symlink?(destination)
      raise Error, stale(source.fetch('id')) if File.exist?(destination) && !recorded?(source)

      Dir.mktmpdir('.source-', parent) do |temporary|
        extracted = File.join(temporary, 'tree')
        if %w[tar git].include?(source.fetch('kind'))
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
        marker = File.join(extracted, '.source.json')
        if File.exist?(marker) || File.symlink?(marker)
          raise Error, 'source archive conflicts with its provenance marker'
        end
        File.write(marker, JSON.pretty_generate(source) + "\n")
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
