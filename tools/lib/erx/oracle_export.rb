# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'set'
require_relative 'json_input'

module Erx
  # A stopped, read-only native workspace is the source. The host stage is
  # fresh and private. No workload-selected path or archive reaches this API.
  module OracleExport
    DEFAULT_LIMITS = { 'entries' => 100_000, 'files' => 50_000, 'depth' => 32,
                       'path_bytes' => 2048, 'file_bytes' => 64 * 1024 * 1024,
                       'total_bytes' => 1024 * 1024 * 1024,
                       'inventory_bytes' => 32 * 1024 * 1024 }.freeze
    OPERATIONS = %w[probe build run detached install].freeze
    SUITES = %w[emulator kernel stdlib compiler].freeze
    REASONS = %w[missing excluded_symlink excluded_special unreadable file_limit file_bytes_limit
                 total_bytes_limit depth_limit path_limit entry_limit inventory_limit copy_failed
                 private_fixture source_unavailable invalid_library_list outside_library_directories].freeze
    # The install export brings out the installed tree and the libraries the
    # image's dynamic loader listed for its programs during the workload. The
    # list names image paths; each is copied under libraries/ at its listed
    # name, from the regular file it resolves to in the image's library
    # directories.
    LIBRARY_LIST = 'libraries.json'
    # The installed programs Linux's Erlang guest runs (design-bench.md,
    # "Linux's Erlang guest"): the loader lists their libraries, and each
    # must arrive as a regular file of the installed ERTS directory.
    INSTALL_PROGRAMS = %w[beam.smp erlexec erl_child_setup epmd inet_gethost].freeze
    # A file of an installed ERTS bin directory: the directory, then the file's name.
    INSTALL_PROGRAM_PATH = %r{\A(install/lib/erlang/erts-[0-9]+(?:\.[0-9]+)*/bin)/([^/]+)\z}.freeze
    # The directory the oracle's container works in: it installs OTP at
    # GUEST_ROOT/install, which install/ of an export copies.
    GUEST_ROOT = '/tmp/erx-oracle'
    LIBRARY_DIRECTORIES = %w[lib lib64 usr/lib usr/lib64].freeze
    LIBRARY_LIST_KEYS = %w[libraries version].freeze
    LIBRARY_LIST_BYTES = 64 * 1024
    PLAN_KEYS = %w[identity from].freeze
    PRIVATE_FIXTURE = /\Alog_private(?:\.\d+|\.cfg\.\d+)?\z/.freeze
    CHUNK_BYTES = 65_536
    module_function

    # system_root is the image whose libraries an install export copies: the
    # exporter's own root filesystem, which no workload wrote. Tests name a
    # made-up tree instead; its absolute links resolve on the host and so
    # fall outside its library directories.
    def call(source:, destination:, operation:, suite: nil, limits: DEFAULT_LIMITS, system_root: '/',
             open_destination: File.method(:open), list_source_directory: Dir.method(:each_child))
      Export.new(source: source, destination: destination, operation: operation, suite: suite, limits: limits,
                 system_root: system_root, open_destination: open_destination,
                 list_source_directory: list_source_directory).call
    end

    def verify(destination:, limits: DEFAULT_LIMITS)
      Verifier.new(destination: destination, limits: limits).call
    end

    module Rules
      module_function

      def limits(value)
        unless value.is_a?(Hash) && value.keys.sort == DEFAULT_LIMITS.keys.sort &&
               value.all? { |name, limit| limit.is_a?(Integer) && limit.between?(1, DEFAULT_LIMITS.fetch(name)) } &&
               value.fetch('inventory_bytes') >= 4096
          raise Error, 'invalid oracle artifact limits'
        end
        value.dup.freeze
      end

      def selection(operation, suite)
        unless OPERATIONS.include?(operation) && (operation == 'run' ? SUITES.include?(suite) : suite.nil?)
          raise Error, 'invalid oracle export operation or suite'
        end
        return nil unless operation == 'run'
        suite == 'emulator' ? 'source/erts/emulator/make_test_dir/ct_logs' : "source/lib/#{suite}/make_test_dir/ct_logs"
      end

      def relative(value, limits)
        return nil unless value.is_a?(String) && value.bytesize.between?(1, limits.fetch('path_bytes'))
        text = value.dup.force_encoding(Encoding::UTF_8)
        return nil unless text.valid_encoding? && !text.match?(/[\x00-\x1f\x7f]/) &&
                          text.split('/', -1).none? { |part| ['', '.', '..'].include?(part) } &&
                          text.split('/').size <= limits.fetch('depth')
        text.freeze
      end

      def collision_key(path)
        path.unicode_normalize(:nfd).downcase(:fold).unicode_normalize(:nfd)
      end

      def required?(path, operation, ct_root)
        path == 'result.json' || (operation == 'run' && path == 'events.jsonl') ||
          (operation == 'install' && (path == 'install' || install_member?(path)))
      end

      def install_member?(path) = path.start_with?('install/') || library?(path)

      def library?(path) = path.start_with?(*LIBRARY_DIRECTORIES.map { |directory| "libraries/#{directory}/" })

      # The design exports no links; one inside the installed tree is an
      # expected exclusion, since the guest runs the regular files they name.
      # The guest's own programs must be such files, which status checks.
      def required_link?(path, operation) = !(operation == 'install' && path.start_with?('install/'))

      def ct_path?(path, ct_root)
        ct_root && path.start_with?(ct_root + '/') &&
          path.delete_prefix(ct_root + '/').split('/').none? { |part| part.match?(PRIVATE_FIXTURE) }
      end

      def report?(path, ct_root)
        ct_path?(path, ct_root) && File.basename(path) == 'junit_report.xml'
      end

      def allowed?(path, operation, ct_root)
        path == 'result.json' || path.start_with?('logs/') ||
          (operation == 'run' && (path == 'events.jsonl' || ct_path?(path, ct_root))) ||
          (operation == 'probe' && path.start_with?('image-licenses/')) ||
          (operation == 'detached' && %w[parent-finished detached-heartbeat detached-ready].include?(path)) ||
          (operation == 'install' && install_member?(path))
      end

      def status(inventory)
        files = inventory.fetch('files')
        omissions = inventory.fetch('omissions')
        operation = inventory.fetch('operation')
        ct_root = selection(operation, inventory.fetch('suite'))
        paths = files.map { |file| file.fetch('path') }
        mandatory = paths.include?('result.json') && omissions.none? { |issue| issue.fetch('required') }
        if operation == 'run'
          mandatory &&= paths.include?('events.jsonl')
        elsif operation == 'install'
          # A plan cut short by a budget may have dropped required files
          # without a record of each, so it is never complete evidence; and
          # each guest program must be a regular file, since the guest runs it.
          programs = paths.filter_map { |path| path[INSTALL_PROGRAM_PATH, 2] }
          mandatory &&= %w[install/ libraries/].all? { |prefix| paths.any? { |path| path.start_with?(prefix) } } &&
                        omissions.none? { |issue| %w[entry_limit inventory_limit].include?(issue.fetch('reason')) } &&
                        (INSTALL_PROGRAMS - programs).empty?
        end
        [omissions.any? { |issue| issue.fetch('reason') != 'private_fixture' } ? 'partial' : 'complete',
         mandatory ? 'complete' : 'partial']
      end

      def identity(stat)
        [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime].freeze
      end

      def omission(path, reason:, required:, limits:)
        rendered = Terminal.escape(path)
        maximum = limits.fetch('path_bytes') * 12 + 256
        truncated = rendered.bytesize > maximum
        rendered = rendered.byteslice(0, maximum - 3) + '...' if truncated
        { 'path' => rendered, 'path_truncated' => truncated,
          'reason' => reason, 'required' => required }.freeze
      end

      def root(path)
        stat = File.lstat(path)
        raise Error, 'oracle export root must be an ordinary directory' unless stat.directory? && !stat.symlink?
        File.realpath(path)
      end

      def read_regular(path, maximum:)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
          raise Error, 'oracle inventory is not a bounded regular file' unless input.stat.file? && input.size <= maximum
          bytes = input.read(maximum + 1) || ''.b
          raise Error, 'oracle inventory exceeds byte bound' if bytes.bytesize > maximum
          bytes
        end
      end
    end
    private_constant :Rules

    class Export
      def initialize(source:, destination:, operation:, suite:, limits:, system_root: '/',
                     open_destination: File.method(:open), list_source_directory: Dir.method(:each_child))
        @system_root = File.expand_path(system_root)
        @open_destination = open_destination
        @list_source_directory = list_source_directory
        @source = File.expand_path(source)
        @destination = Rules.root(destination)
        @limits = Rules.limits(limits)
        @operation = operation
        @suite = suite
        @ct_root = Rules.selection(operation, suite)
      end

      def call
        raise Error, 'oracle artifact destination must be fresh' unless Dir.empty?(@destination)
        plan = plan_files
        copied = []
        issues = plan.fetch('omissions').dup
        plan.fetch('files').each do |file|
          result = copy_file(file)
          result.key?('sha256') ? copied << result : issues << result
        end
        inventory = document(files: copied, omissions: issues)
        bytes = JSON.generate(inventory, ascii_only: true) + "\n"
        raise Error, 'oracle inventory exceeds its preflight budget' if bytes.bytesize > @limits.fetch('inventory_bytes')
        File.open(File.join(@destination, 'export.json'), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
          output.write(bytes)
          output.flush
          output.fsync
        end
        freeze_document(inventory)
      rescue SystemCallError, IOError => error
        raise Error, "oracle artifact export failed: #{error.class}"
      end

      private

      def document(files:, omissions:)
        result = { 'version' => 1, 'operation' => @operation, 'suite' => @suite, 'limits' => @limits,
                   'files' => files.sort_by { |file| file.fetch('path').b },
                   'omissions' => omissions.sort_by { |issue| [issue.fetch('path').b, issue.fetch('reason')] } }
        state, mandatory = Rules.status(result)
        result.merge('state' => state, 'mandatory_evidence' => mandatory)
      end

      # Preflight stores only bounded metadata. Mandatory evidence is selected
      # before ancillary files; no destination entry exists until this returns.
      def plan_files
        @candidates = []
        @issues = []
        @keys = {}
        @entries = 1 + (@ct_root ? @ct_root.split('/').size - 1 : 0)
        @stopped = false
        @metadata_bytes = JSON.generate(document(files: [], omissions: [])).bytesize + 4096
        unless File.exist?(@source)
          issue('result.json', 'source_unavailable', required: true)
          return { 'files' => [], 'omissions' => @issues.freeze }.freeze
        end
        @source = Rules.root(@source)
        roots = ['result.json']
        roots.concat(['events.jsonl', @ct_root]) if @operation == 'run'
        roots << 'logs'
        roots << 'image-licenses' if @operation == 'probe'
        roots << 'install' if @operation == 'install'
        roots.concat(%w[parent-finished detached-heartbeat detached-ready]) if @operation == 'detached'
        roots.each { |path| walk(path) unless @stopped }
        plan_libraries if @operation == 'install' && !@stopped
        total = 0
        selected = []
        @candidates.sort_by { |file| [file.fetch('required') ? 0 : 1, file.fetch('path').b] }.each do |file|
          if selected.size >= @limits.fetch('files')
            issue(file.fetch('path'), 'file_limit', required: file.fetch('required'))
          elsif file.fetch('size') > @limits.fetch('total_bytes') - total
            issue(file.fetch('path'), 'total_bytes_limit', required: file.fetch('required'))
          else
            total += file.fetch('size')
            selected << file.freeze
          end
        end
        { 'files' => selected.freeze, 'omissions' => @issues.freeze }.freeze
      end

      def walk(root)
        pending = [root]
        until pending.empty? || @stopped
          raw = pending.pop
          required = Rules.required?(raw, @operation, @ct_root)
          unless (path = Rules.relative(raw, @limits))
            issue(raw, raw.split('/').size > @limits.fetch('depth') ? 'depth_limit' : 'path_limit', required: required)
            next
          end
          @entries += 1
          if @entries > @limits.fetch('entries')
            issue(path, 'entry_limit', required: required)
            @stopped = true
            next
          end
          if @ct_root && path.start_with?(@ct_root + '/') && File.basename(path).match?(PRIVATE_FIXTURE)
            issue(path, 'private_fixture', required: false)
            next
          end
          begin
            stat = source_stat(path)
            if stat.symlink?
              issue(path, 'excluded_symlink', required: required && Rules.required_link?(path, @operation))
            elsif stat.directory?
              collision(path)
              names = []
              available = @limits.fetch('entries') - @entries - pending.size
              @list_source_directory.call(File.join(@source, path)) do |name|
                names << name.b
                break if names.size > available
              end
              if names.size > available
                issue(path, 'entry_limit', required: false)
                @stopped = true
              else
                pending.concat(names.sort.reverse.map { |name| path.b + '/'.b + name })
              end
            elsif stat.file?
              admit_file(path, stat, required: required, from: File.join(@source, path))
            else
              issue(path, 'excluded_special', required: required)
            end
          rescue Errno::ENOENT, Errno::ENOTDIR
            issue(path, 'missing', required: required)
          rescue Errno::ELOOP
            issue(path, 'excluded_symlink', required: required && Rules.required_link?(path, @operation))
          rescue Errno::EACCES, Errno::EPERM
            issue(path, 'unreadable', required: required)
          end
        end
      end

      def admit_file(path, stat, required:, from:)
        collision(path)
        if stat.size > @limits.fetch('file_bytes')
          issue(path, 'file_bytes_limit', required: required)
        else
          file = { 'path' => path, 'size' => stat.size, 'required' => required,
                   'identity' => Rules.identity(stat), 'from' => from }
          preview = published(file).merge('sha256' => '0' * 64)
          failure = Rules.omission(path, reason: 'copy_failed', required: required, limits: @limits)
          @candidates << file if admit_metadata(preview, alternative: failure)
        end
      end

      def published(file) = file.reject { |name, _| PLAN_KEYS.include?(name) }.merge('type' => 'file')

      # The list is the workload's, so untrusted: a listed name must lie in
      # the image's library directories, and so must the regular file it
      # resolves to there. Links are followed only in the image, never in
      # the workspace.
      def plan_libraries
        names = library_list or return
        roots = LIBRARY_DIRECTORIES.filter_map do |directory|
          File.realpath(File.join(@system_root, directory))
        rescue SystemCallError
          nil
        end.uniq
        names.each do |name|
          break if @stopped
          path = library_path(name)
          next issue(LIBRARY_LIST, 'invalid_library_list', required: true) unless path
          next issue(path, 'outside_library_directories', required: true) unless Rules.library?(path)
          @entries += 1
          if @entries > @limits.fetch('entries')
            issue(path, 'entry_limit', required: true)
            @stopped = true
            next
          end
          begin
            resolved = File.realpath(File.join(@system_root, path.delete_prefix('libraries/')))
            next issue(path, 'outside_library_directories', required: true) unless resolved.start_with?(*roots.map { |root| root + '/' })
            stat = File.lstat(resolved)
            next issue(path, 'excluded_special', required: true) unless stat.file?
            admit_file(path, stat, required: true, from: resolved)
          rescue Errno::ENOENT, Errno::ENOTDIR
            issue(path, 'missing', required: true)
          rescue Errno::ELOOP
            issue(path, 'excluded_symlink', required: true)
          rescue Errno::EACCES, Errno::EPERM
            issue(path, 'unreadable', required: true)
          end
        end
      end

      # A listed name is absolute; its staging path keeps it under libraries/.
      # A malformed name is refused without echoing it into the inventory.
      def library_path(name)
        return nil unless name.start_with?('/') && Rules.relative(name.delete_prefix('/'), @limits)
        Rules.relative("libraries#{name}", @limits)
      end

      def library_list
        stat = source_stat(LIBRARY_LIST)
        unless stat.file?
          issue(LIBRARY_LIST, stat.symlink? ? 'excluded_symlink' : 'excluded_special', required: true)
          return nil
        end
        bytes = Rules.read_regular(File.join(@source, LIBRARY_LIST), maximum: LIBRARY_LIST_BYTES)
        list = JsonInput.parse(bytes, max_bytes: LIBRARY_LIST_BYTES, label: 'oracle library list')
        unless list.is_a?(Hash) && list.keys.sort == LIBRARY_LIST_KEYS && list['version'] == 1 &&
               list['libraries'].is_a?(Array) && list['libraries'].all?(String)
          raise Error, 'invalid oracle library list'
        end
        list.fetch('libraries').uniq
      rescue Errno::ENOENT, Errno::ENOTDIR
        issue(LIBRARY_LIST, 'missing', required: true)
        nil
      rescue Errno::EACCES, Errno::EPERM
        issue(LIBRARY_LIST, 'unreadable', required: true)
        nil
      rescue Error
        issue(LIBRARY_LIST, 'invalid_library_list', required: true)
        nil
      end

      # Check every selected-root ancestor too: lstat of a leaf alone would
      # follow a symlink earlier in source/lib/.../ct_logs.
      def source_stat(path)
        cursor = @source
        parts = path.split('/')
        parts.each_with_index do |part, index|
          cursor = File.join(cursor, part)
          stat = File.lstat(cursor)
          return stat if index == parts.size - 1
          raise Errno::ELOOP if stat.symlink?
          raise Errno::ENOTDIR unless stat.directory?
        end
      end

      def collision(path)
        key = Rules.collision_key(path)
        raise Error, 'oracle artifact pathname collision' if @keys.key?(key) && @keys.fetch(key) != path
        @keys[key] = path
      end

      def admit_metadata(record, alternative: nil)
        cost = [record, alternative].compact.map { |value| JSON.generate(value, ascii_only: true).bytesize + 1 }.max
        if cost > @limits.fetch('inventory_bytes') - @metadata_bytes
          unless @stopped
            @issues << Rules.omission('.', reason: 'inventory_limit', required: false, limits: @limits)
          end
          @stopped = true
          false
        else
          @metadata_bytes += cost
          true
        end
      end

      def issue(path, reason, required:)
        record = Rules.omission(path, reason: reason, required: required, limits: @limits)
        @issues << record if admit_metadata(record)
      end

      def destination_parents(path)
        path.split('/')[0...-1].reduce(@destination) do |parent, name|
          current = File.join(parent, name)
          if File.exist?(current) || File.symlink?(current)
            stat = File.lstat(current)
            raise Error, 'oracle artifact parent is not an ordinary directory' unless stat.directory? && !stat.symlink?
          else
            Dir.mkdir(current, 0o700)
          end
          current
        end
      end

      def copy_file(file)
        path = file.fetch('path')
        target = File.join(@destination, path)
        created = false
        hash = Digest::SHA256.new
        begin
          File.open(file.fetch('from'), File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
            unless input.stat.file? && Rules.identity(input.stat) == file.fetch('identity')
              raise Error, 'oracle artifact changed after planning'
            end
            destination_parents(path)
            @open_destination.call(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
              created = true
              remaining = file.fetch('size')
              while remaining.positive?
                bytes = input.read([remaining, CHUNK_BYTES].min)
                raise Error, 'oracle artifact was truncated during copy' if bytes.nil? || bytes.empty?
                hash.update(bytes)
                raise Error, 'oracle artifact copy wrote a short block' unless output.write(bytes) == bytes.bytesize
                remaining -= bytes.bytesize
              end
              output.flush
              unless Rules.identity(input.stat) == file.fetch('identity') && output.stat.size == file.fetch('size')
                raise Error, 'oracle artifact changed during copy'
              end
            end
          end
          published(file).merge('sha256' => hash.hexdigest).freeze
        rescue SystemCallError, IOError, Error => error
          begin
            File.unlink(target) if created
            remove_empty_parents(File.dirname(target))
          rescue SystemCallError, Error => cleanup_error
            raise Error, "oracle copy failed (#{error.class}) and partial-copy cleanup failed (#{cleanup_error.class})"
          end
          Rules.omission(path, reason: 'copy_failed', required: file.fetch('required'), limits: @limits)
        end
      end

      def remove_empty_parents(directory)
        until directory == @destination
          begin
            stat = File.lstat(directory)
          rescue Errno::ENOENT
            break
          end
          unless stat.directory? && !stat.symlink?
            raise Error, 'oracle partial-copy parent has an unexpected type'
          end
          begin
            Dir.rmdir(directory)
          rescue Errno::ENOTEMPTY, Errno::EEXIST
            break
          end
          directory = File.dirname(directory)
        end
      end

      def freeze_document(value)
        case value
        when Hash then value.each { |key, member| freeze_document(key); freeze_document(member) }
        when Array then value.each { |member| freeze_document(member) }
        end
        value.freeze
      end
    end
    private_constant :Export

    class Verifier
      def initialize(destination:, limits:)
        @destination = Rules.root(destination)
        @limits = Rules.limits(limits)
      end

      def call
        bytes = Rules.read_regular(File.join(@destination, 'export.json'), maximum: @limits.fetch('inventory_bytes'))
        inventory = JsonInput.parse(bytes, max_bytes: @limits.fetch('inventory_bytes'), label: 'oracle artifact inventory')
        namespace = validate(inventory)
        verify_tree(inventory, namespace: namespace)
        inventory.freeze
      rescue SystemCallError, IOError => error
        raise Error, "cannot verify oracle artifacts: #{error.class}"
      end

      private

      def validate(inventory)
        unless inventory.is_a?(Hash) && inventory.keys.sort == %w[files limits mandatory_evidence omissions operation state suite version] &&
               inventory['version'] == 1 && inventory['limits'] == @limits &&
               inventory['files'].is_a?(Array) && inventory['files'].size <= @limits.fetch('files') &&
               inventory['omissions'].is_a?(Array) && inventory['omissions'].size <= @limits.fetch('entries')
          raise Error, 'invalid oracle inventory shape or bounds'
        end
        operation = inventory.fetch('operation')
        ct_root = Rules.selection(operation, inventory.fetch('suite'))
        total = 0
        previous = nil
        inventory.fetch('files').each do |file|
          unless file.is_a?(Hash) && file.keys.sort == %w[path required sha256 size type] &&
                 (path = Rules.relative(file['path'], @limits)) && file['type'] == 'file' &&
                 [true, false].include?(file['required']) && file['required'] == Rules.required?(path, operation, ct_root) &&
                 Rules.allowed?(path, operation, ct_root) && file['size'].is_a?(Integer) &&
                 file['size'].between?(0, @limits.fetch('file_bytes')) &&
                 file['sha256'].is_a?(String) && file['sha256'].match?(/\A[0-9a-f]{64}\z/)
            raise Error, 'invalid oracle copied-file record'
          end
          raise Error, 'oracle file paths are not strictly ordered' if previous && previous.b >= path.b
          previous = path
          total += file.fetch('size')
          raise Error, 'oracle copied bytes exceed aggregate bound' if total > @limits.fetch('total_bytes')
        end
        inventory.fetch('omissions').each do |issue|
          unless issue.is_a?(Hash) && issue.keys.sort == %w[path path_truncated reason required] &&
                 issue['path'].is_a?(String) && issue['path'].ascii_only? &&
                 issue['path'].bytesize <= @limits.fetch('path_bytes') * 12 + 256 &&
                 issue['path'].bytes.all? { |byte| byte.between?(32, 126) } &&
                 [true, false].include?(issue['path_truncated']) &&
                 (!issue['path_truncated'] || issue['path'].end_with?('...')) &&
                 [true, false].include?(issue['required']) && REASONS.include?(issue['reason'])
            raise Error, 'invalid oracle omission record'
          end
        end
        state, mandatory = Rules.status(inventory)
        unless inventory['state'] == state && inventory['mandatory_evidence'] == mandatory
          raise Error, 'oracle inventory evidence status disagrees with its contents'
        end
        namespace(inventory.fetch('files'))
      end

      # Every canonical pathname has one spelling and one type. Deriving the
      # whole namespace first prevents an alleged file from becoming a parent.
      def namespace(files)
        entries = {}
        canonical = {}
        add = lambda do |path, type|
          key = Rules.collision_key(path)
          previous = canonical[key]
          if previous && (previous != path || entries.fetch(previous) != type)
            raise Error, 'oracle inventory namespace pathname collision'
          end
          canonical[key] = path
          entries[path] = type
          raise Error, 'oracle exported entries exceed bound' if entries.size > @limits.fetch('entries')
        end
        add.call('export.json', 'file')
        files.each do |file|
          parts = file.fetch('path').split('/')
          (1...parts.size).each { |count| add.call(parts.take(count).join('/'), 'directory') }
          add.call(file.fetch('path'), 'file')
        end
        entries.freeze
      end

      def verify_tree(inventory, namespace:)
        files = inventory.fetch('files').to_h { |file| [file.fetch('path'), file] }
        expected = namespace.keys.to_set
        found = Set.new
        pending = ['']
        until pending.empty?
          parent = pending.pop
          Dir.each_child(File.join(@destination, parent)) do |name|
            path = parent.empty? ? name : parent + '/' + name
            raise Error, 'unexpected oracle artifact entry' unless expected.include?(path) && !found.include?(path)
            found << path
            stat = File.lstat(File.join(@destination, path))
            if namespace.fetch(path) == 'directory'
              raise Error, 'oracle artifact directory has unsafe type or mode' unless stat.directory? && !stat.symlink? && (stat.mode & 0o777) == 0o700
              pending << path
            else
              unless stat.file? && !stat.symlink? && (stat.mode & 0o777) == 0o600
                raise Error, 'oracle artifact file has unsafe type or mode'
              end
              next if path == 'export.json'
              record = files.fetch(path)
              raise Error, 'oracle artifact size differs from inventory' unless stat.size == record.fetch('size')
              digest = Digest::SHA256.new
              File.open(File.join(@destination, path), File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
                before = Rules.identity(input.stat)
                remaining = record.fetch('size')
                while remaining.positive?
                  block = input.read([remaining, CHUNK_BYTES].min)
                  raise Error, 'oracle artifact truncated during verification' if block.nil? || block.empty?
                  digest.update(block)
                  remaining -= block.bytesize
                end
                raise Error, 'oracle artifact changed during verification' unless before == Rules.identity(input.stat)
              end
              raise Error, 'oracle artifact digest differs from inventory' unless digest.hexdigest == record.fetch('sha256')
            end
          end
        end
        raise Error, 'oracle inventory references missing artifacts' unless found == expected
      end
    end
    private_constant :Verifier
  end
end
