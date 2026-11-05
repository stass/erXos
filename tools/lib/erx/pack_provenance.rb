# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'pathname'
require_relative 'origin'
require_relative 'archive_member'
require_relative 'license_expression'
require_relative 'build_inputs'
require_relative 'import_notices'

module Erx
  # A receipt binds the actual output, link map and compiler dependency files.
  # Licences are derived from those inputs, never asserted by the caller that
  # requests an image. External files require exact reviewed registry entries.
  class PackProvenance
    MAX_METADATA = 64 * 1024 * 1024
    # compiler is the clang that built Fiasco's C17 cores, which Fiasco's audit records.
    def initialize(root:, catalog:, external: [], imports: {}, runner: nil, archive_program: 'llvm-ar', compiler: nil)
      @root = File.realpath(root)
      @compiler = compiler
      raise Error, 'source checking requires a catalog from its trusted builder' unless catalog.is_a?(BuildInputs)
      @catalog = catalog
      @external = {}
      @registered_paths = {}
      register_external(external)
      @origins = {}
      @runner = runner
      @archive_program = archive_program
      @imports = imports.to_h do |path, status|
        canonical = File.realpath(File.expand_path(path, @root))
        @catalog = @catalog.merge(BuildInputs.imported(root: canonical)) unless @catalog.find_import(canonical)
        [canonical, status]
      end
    end

    # Returns only stable, public names. The caller may include these facts in
    # manifest admission and render NOTICES from the same checked closure.
    def resolve(receipt:, artifact:, build_kind:, notice_budget: MAX_METADATA)
      raise Error, 'unknown provenance build kind' unless %w[development release].include?(build_kind)
      unless notice_budget.is_a?(Integer) && notice_budget.positive?
        raise Error, 'invalid provenance notice budget'
      end
      @notice_limit = [notice_budget, MAX_METADATA].min
      @notice_bytes = 0
      @notice_documents = {}
      @metadata = {}
      @origins = {}
      @verified = {}
      @verified_bytes = 0
      @completed_receipts = {}
      records = {}
      seen = {}
      checked = visit(File.expand_path(path_value(receipt), @root), records: records, seen: seen,
                      build_kind: build_kind, depth: 0)
      artifact_path = authorized_path(artifact)
      unless checked.fetch('path') == artifact_path &&
             checked.fetch('sha256') == @catalog.verify(artifact_path).fetch('sha256')
        raise Error, 'receipt is not bound to the requested artifact'
      end
      records.values.sort_by { |record| record.fetch('path').b }.freeze
    rescue KeyError, Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => error
      raise Error, "invalid build receipt: #{error.message}"
    end

    def artifact_hash(path)
      @catalog.entry(path).fetch('sha256')
    end

    def notices(records, budget: MAX_METADATA)
      raise Error, 'invalid image notice budget' unless budget.is_a?(Integer) && budget.positive?
      parts = ["erXos image source notices\n\n".b]
      records.each do |record|
        parts << record.fetch('path') << "\nLicense: " << record.fetch('license')
        parts << "\nEvidence: " << record.fetch('evidence') << "\n" << record.fetch('notice') << "\n\n"
      end
      raise Error, 'image notices exceed host budget' if parts.sum(&:bytesize) > budget
      parts.join.b.freeze
    end

    # Make dependency syntax has escaped whitespace and continued lines. It is
    # not shell syntax; no command, variable or wildcard expansion takes place.
    def self.dependencies(bytes)
      raise Error, 'dependency file is too large' if bytes.bytesize > MAX_METADATA
      rules = bytes.gsub(/\\\r?\n/, '').lines.reject { |line| line.strip.empty? }
      raise Error, 'dependency file has no rule' if rules.empty?
      targets, sources = dependency_rule(rules.first)
      raise Error, 'dependency rule has no sources' if sources.empty?
      rules.drop(1).each do |line|
        phony_targets, phony_sources = dependency_rule(line)
        unless phony_sources.empty? && phony_targets.all? { |target| sources.include?(target) }
          raise Error, 'unsupported compiler phony dependency rule'
        end
      end
      [targets, sources].freeze
    end

    def self.dependency_rule(text)
      words = []
      token = ''.b
      escaped = false
      target_end = nil
      text.each_byte do |byte|
        if escaped
          token << byte
          escaped = false
        elsif byte == 92
          escaped = true
        elsif byte == 58 && target_end.nil?
          words << token unless token.empty?
          token = ''.b
          target_end = words.size
        elsif [9, 10, 13, 32].include?(byte)
          words << token unless token.empty?
          token = ''.b
        elsif byte == 0 || byte == 36 || byte == 35 || byte == 58
          raise Error, 'unsupported dependency syntax'
        else
          token << byte
        end
      end
      raise Error, 'unterminated dependency escape' if escaped
      words << token unless token.empty?
      unless target_end && target_end.positive?
        raise Error, 'dependency rule has no target'
      end
      [words.take(target_end).freeze, words.drop(target_end).uniq.freeze].freeze
    end
    private_class_method :dependency_rule

    # Input columns identify contributions; filename suffixes have no meaning
    # to a linker. GNU's discarded-section preamble is outside this closure.
    def self.contributors(bytes, format:)
      raise Error, 'link map is too large' if bytes.bytesize > MAX_METADATA
      text = bytes
      if format == 'gnu'
        _discarded, marker, text = text.partition('Linker script and memory map')
        raise Error, 'GNU link map has no allocated section' if marker.empty?
      elsif format != 'lld'
        raise Error, 'unsupported link map format'
      end
      result = text.lines.map do |line|
        if format == 'lld'
          row = /\A\s*[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+\d+\s+(.+?)\s*\z/.match(line)
          next unless row
          # Output-section and symbol rows have no input-section delimiter.
          next unless row[1].include?(':(')
          input = /\A(.+):\([^()]*\)\z/.match(row[1])
          raise Error, 'unsupported LLD input contribution' unless input
          next if input[1] == '<internal>'
          input[1]
        else
          next if line.match?(/\A\s*\*fill\*\s/)
          row = /\A\s*(?:[^\s]+\s+)?0x[0-9a-fA-F]+\s+0x[0-9a-fA-F]+\s+(.+?)\s*\z/.match(line)
          next unless row
          next if row[1].match?(/\Aload address 0x[0-9a-fA-F]+\z/)
          # These are bytes emitted by the linker script, not input files.
          next if row[1].match?(/\A(?:BYTE|SHORT|LONG|QUAD|SQUAD) 0x[0-9a-fA-F]+(?: [A-Za-z_][A-Za-z0-9_]*| \([A-Za-z_][A-Za-z0-9_]* [-+] [A-Za-z_][A-Za-z0-9_]*\))?\z/)
          row[1]
        end
      end.compact.uniq
      unless result.all? { |input| input.match?(/\A[^\s()]+(?:\([^\s()]+\))?\z/) }
        raise Error, 'unsupported link input name'
      end
      raise Error, 'link map contains no object contributions' if result.empty?
      result.freeze
    end

    private

    def visit(path, records:, seen:, build_kind:, depth:, expected: nil)
      raise Error, 'receipt graph exceeds its depth bound' if depth >= 16
      path = authorized_path(path, expected: expected)
      raise Error, 'cyclic build receipt' if seen[path]
      return @completed_receipts.fetch(path) if @completed_receipts.key?(path)
      seen[path] = true
      bytes = snapshot_bytes(path, expected: expected)
      receipt = JsonInput.parse(bytes, max_bytes: MAX_METADATA, label: 'build receipt')
      raise Error, 'unsupported build receipt version' unless receipt.is_a?(Hash) && receipt['version'] == 1
      if receipt['kind'] == 'fiasco'
        exact_keys(receipt, %w[version kind artifact audit])
        fixed_fiasco_path(receipt.fetch('artifact'), 'images/bootstrap.raw')
        fixed_fiasco_path(receipt.fetch('audit'), 'provenance.json')
      end
      output = checked_file(receipt.fetch('artifact'))
      case receipt.fetch('kind')
      when 'assembled'
        exact_keys(receipt, %w[version kind artifact components producer])
        attribute(checked_file(receipt.fetch('producer')).fetch('path'), records, build_kind)
        components = receipt.fetch('components')
        raise Error, 'assembled receipt has no components' unless components.is_a?(Array) && components.size.between?(1, 64)
        components.each do |component|
          file = checked_file(component)
          visit(file.fetch('path'), records: records, seen: seen,
                build_kind: build_kind, depth: depth + 1, expected: file.fetch('sha256'))
        end
      when 'linked'
        exact_keys(receipt, %w[version kind artifact linker_map compiles archives inputs])
        resolve_link(receipt, records: records, build_kind: build_kind)
      when 'fiasco'
        resolve_fiasco(receipt, records: records, build_kind: build_kind)
      when 'compiled'
        # A file with no link to read, Erlang's. This attributes licences to the sources it
      # names and proves nothing about what the file was made from.
        exact_keys(receipt, %w[version kind artifact sources])
        sources = receipt.fetch('sources')
        raise Error, 'compiled receipt has no sources' unless sources.is_a?(Array) && sources.size.between?(1, 64)
        sources.each { |source| attribute(checked_file(source).fetch('path'), records, build_kind) }
      else
        raise Error, 'unknown build receipt kind'
      end
      seen.delete(path)
      @completed_receipts[path] = output.freeze
    end

    def fixed_fiasco_path(reference, relative)
      exact_keys(reference, %w[path sha256])
      expected = File.join(@root, 'build/fiasco', relative)
      declared = File.expand_path(path_value(reference.fetch('path')), @root)
      unless declared == expected && File.realpath(declared) == expected
        raise Error, 'Fiasco receipts require the fixed backend artifact and audit paths'
      end
    end

    def resolve_fiasco(receipt, records:, build_kind:)
      raise Error, 'Fiasco provenance requires a command runner' unless @runner
      require_relative 'fiasco_provenance'
      expected = verified_read(receipt.fetch('audit'))
      external, fresh, catalog = fresh_fiasco_audit
      raise Error, 'Fiasco auditor did not supply its checked input catalog' unless catalog.is_a?(BuildInputs)
      @catalog = @catalog.merge(catalog)
      unless fresh.fetch('state') == 'complete' && FiascoProvenance.canonical_report(fresh) == expected
        raise Error, 'Fiasco build record is stale or incomplete'
      end
      image = fresh.fetch('image').fetch('artifact')
      unless File.expand_path(image.fetch('path'), @root) == File.expand_path(receipt.fetch('artifact').fetch('path'), @root) &&
             image.fetch('sha256') == receipt.fetch('artifact').fetch('sha256')
        raise Error, 'Fiasco audit does not bind the admitted final image'
      end
      register_external(external)
      FiascoProvenance::PARTS.each do |part|
        [File.join(@root, 'fiasco', part), File.join(@root, 'build/fiasco/inputs/fiasco', part)].each do |directory|
          @imports[directory] = 'stopgap' if File.directory?(directory) && @catalog.find_import(directory)
        end
      end
      fresh.fetch('sources').each do |source|
        next unless source.key?('license')
        path = source.fetch('source', source.fetch('path'))
        selected = LicenseExpression.select(source.fetch('license'), allow_restricted: build_kind == 'development')
        notices = source.fetch('notices', []) + selected.fetch('grants').flat_map do |grant|
          fresh.fetch('license_notices', {}).fetch(grant, [])
        end
        # A file erXos added to the fork is in no import's inventory, nor is a core's copy
        # under Fiasco's inputs, so the audit's finding is their attribution. An addition
        # takes erXos's own license for its notice.
        addition = source['evidence'].to_s.start_with?('erXos addition')
        notices += [{ 'path' => 'LICENSE', 'sha256' => @catalog.entry(File.join(@root, 'LICENSE')).fetch('sha256') }] if addition
        attribute(File.expand_path(path, @root), records, build_kind, additional_notices: notices,
                  public_path: source['original_source'], audited: source)
      end
    end

    def fresh_fiasco_audit
      # One audit answers every receipt of this resolver: it reads the whole of Fiasco's
      # build, and an image names that build once per entry and again at its snapshot.
      @fiasco_audit ||= begin
        external = FiascoProvenance.external_registry(root: @root, compiler: @compiler)
        auditor = FiascoProvenance.new(root: @root, runner: @runner, external: external, compiler: @compiler)
        fresh = auditor.audit
        [external, fresh, auditor.input_catalog].freeze
      end
    end

    def resolve_link(receipt, records:, build_kind:)
      map = receipt.fetch('linker_map')
      exact_keys(map, %w[path sha256 format directory])
      directory = File.expand_path(path_value(map.fetch('directory')), @root)
      map_bytes = verified_read(map.reject { |key, _| %w[format directory].include?(key) })
      contributors = self.class.contributors(map_bytes, format: map.fetch('format'))
      compiles = receipt.fetch('compiles')
      archives = receipt.fetch('archives')
      inputs = receipt.fetch('inputs')
      unless compiles.is_a?(Array) && archives.is_a?(Array) && inputs.is_a?(Array) &&
             compiles.size + archives.size + inputs.size <= 65_536
        raise Error, 'invalid receipt input lists'
      end
      objects = compiles.to_h do |compile|
        exact_keys(compile, %w[object dependency directory sources])
        object = checked_file(compile.fetch('object'))
        cwd = File.expand_path(path_value(compile.fetch('directory')), @root)
        targets, sources = self.class.dependencies(verified_read(compile.fetch('dependency')))
        unless targets.any? { |target| File.expand_path(target, cwd) == object.fetch('path') }
          raise Error, 'dependency target does not name its compiled object'
        end
        derived = sources.map { |source| authorized_path(File.expand_path(source, cwd)) }.uniq.sort
        source_inventory = compile.fetch('sources')
        unless source_inventory.is_a?(Array) && source_inventory.size.between?(1, 65_536)
          raise Error, 'invalid compiled source inventory'
        end
        declared = source_inventory.map { |source| checked_file(source).fetch('path') }.uniq.sort
        raise Error, 'compiled source inventory disagrees with dependencies' unless derived == declared
        [object.fetch('path'), derived]
      end
      raise Error, 'duplicate object receipt' unless objects.size == compiles.size
      archive_members = archives.each_with_object({}) do |archive, selected|
        exact_keys(archive, %w[path sha256 members])
        file = checked_file(archive.reject { |key, _| key == 'members' })
        members = archive.fetch('members')
        raise Error, 'invalid archive member inventory' unless members.is_a?(Array) && members.size.between?(1, 65_536)
        members.each do |member|
          exact_keys(member, %w[name sha256 object_path])
          object = checked_file('path' => member.fetch('object_path'), 'sha256' => member.fetch('sha256'))
          unless objects.key?(object.fetch('path')) && member.fetch('name').is_a?(String) &&
                 !member.fetch('name').match?(/[\s()\/]/)
            raise Error, 'archive member has no compiled input receipt'
          end
          name = "#{file.fetch('path')}(#{member.fetch('name')})"
          raise Error, 'duplicate archive member receipt' if selected.key?(name)
          raise Error, 'archive verification requires a command runner' unless @runner
          extracted_hash = ArchiveMember.sha256(bytes: verified_read(file), member: member.fetch('name'),
            runner: @runner, program: @archive_program, directory: File.join(@root, 'build'), owner_root: @root, name: 'archive-member')
          unless extracted_hash == object.fetch('sha256')
            raise Error, 'archive member differs from its compiled object'
          end
          selected[name] = object.fetch('path')
        end
      end
      contributors.each do |contributor|
        if contributor.include?('(')
          archive, _separator, member = contributor.partition('(')
          key = "#{File.expand_path(archive, directory)}(#{member}"
          object = archive_members[key]
          unless object
            # A registered archive is keyed by its real path; a link names it as the search path does.
            archive_path = File.realpath(File.expand_path(archive, directory))
            if @external.key?(archive_path)
              attribute(archive_path, records, build_kind)
              next
            end
          end
          raise Error, "unresolved archive contribution: #{contributor}" unless object
        else
          object = File.expand_path(contributor, directory)
        end
        sources = objects[object]
        if sources
          sources.each { |source| attribute(source, records, build_kind) }
        elsif @external.key?(object)
          attribute(object, records, build_kind)
        else
          raise Error, "unresolved linked object: #{object}"
        end
      end
      inputs.each { |input| attribute(checked_file(input).fetch('path'), records, build_kind) }
    end

    def attribute(path, records, build_kind, additional_notices: [], public_path: nil, audited: nil)
      path = authorized_path(path)
      additions = additional_notices.map { |notice| verified_read(notice, maximum: @notice_limit) }
      document_references = additional_notices.map { |notice| notice_reference(notice) }
      if records.key?(path)
        existing = records.fetch(path)
        missing = additions.reject { |text| existing.fetch('notice').include?(text) }
        unless missing.empty?
          records[path] = existing.merge('notice' => retain_notice([existing.fetch('notice'), *missing]),
            'notice_documents' => (existing.fetch('notice_documents') + document_references).uniq.freeze).freeze
        end
        return
      end
      if @external.key?(path)
        checked_file('path' => path, 'sha256' => @external.fetch(path).fetch('sha256'))
      end
      bytes = snapshot_bytes(path, expected: @verified[path])
      hash = Digest::SHA256.hexdigest(bytes)
      if @verified.key?(path) && @verified.fetch(path) != hash
        raise Error, "provenance source changed during admission: #{path}"
      end
      if @external.key?(path)
        external = @external.fetch(path)
        raise Error, "changed external provenance input: #{path}" unless external.fetch('sha256') == hash
        license = external.fetch('license')
        label = external.fetch('label')
        evidence = external.fetch('evidence')
        status = external.fetch('status')
        parts = external.fetch('notices').flat_map { |item| [verified_read(item, maximum: @notice_limit), "\n"] }
        document_references.concat(external.fetch('notices').map { |item| notice_reference(item) })
      elsif path.start_with?(@root + '/')
        label = path.delete_prefix(@root + '/')
        origin_root = find_origin(File.dirname(path))
        status = if origin_root
                   @imports.fetch(origin_root) { audited ? 'permanent' : raise(Error, "unregistered imported dependency: #{label}") }
                 else
                   'permanent'
                 end
        item = origin_root && imported_item(origin_root, path, bytes: bytes, label: label, audited: audited)
        if item
          license = item.fetch('license')
          evidence = item.fetch('evidence')
          parts = [leading_notice(bytes)]
        else
          # Build outputs have no stable staging directory. Content identifies
          # a generated source while preserving its readable file name.
          label = "build/generated/#{hash}/#{File.basename(path)}" if label.start_with?('build/')
          license = Attribution.for_file(label, bytes: bytes, sidecar: nil,
                                         review: { 'rules' => [], 'default_license' => 'NOASSERTION',
                                                   'default_evidence' => '' }).fetch('license')
          evidence = 'file SPDX'
          license_document = File.join(@root, 'LICENSE')
          parts = [leading_notice(bytes), snapshot_bytes(license_document, maximum: @notice_limit)]
          document_references << notice_reference('path' => license_document,
            'sha256' => @catalog.entry(license_document).fetch('sha256'))
        end
      else
        raise Error, "unresolved external provenance input: #{path}"
      end
      Attribution.validate_expression(license)
      raise Error, 'invalid dependency provenance status' unless %w[permanent stopgap].include?(status)
      selected = LicenseExpression.select(license, allow_restricted: build_kind == 'development' && status == 'stopgap')
      if public_path
        unless public_path.is_a?(String) && !public_path.start_with?('/') &&
               public_path.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
          raise Error, 'invalid public source label'
        end
        label = public_path
      end
      if item
        profile_path = File.join(@root, 'config/provenance/import-notices.json')
        references = if @catalog.include_path?(profile_path)
                       profile = @notice_profile ||= ImportNotices.parse(snapshot_bytes(profile_path))
                       ImportNotices.select(profile, source: label, grants: selected.fetch('grants'))
                     else
                       []
                     end
        raise Error, 'selected import grant has no checked notice document' if references.empty? && additions.empty?
        references.each do |reference|
          parts << verified_read(reference, maximum: @notice_limit)
          document_references << notice_reference(reference)
        end
      end
      unless label.is_a?(String) && !label.start_with?('/') && label.valid_encoding? &&
             !label.match?(/[\x00-\x1f\x7f]/)
        raise Error, 'invalid public provenance label'
      end
      notice = retain_notice(parts + additions)
      records[path] = { 'path' => label.freeze, 'sha256' => hash.freeze,
                        'license' => selected.fetch('license'), 'declared_license' => license.freeze,
                        'evidence' => evidence.freeze,
                        'status' => status.freeze, 'notice' => notice.freeze,
                        'notice_documents' => document_references.uniq.freeze }.freeze
    end

    # The inventory row of a file in an import. nil for a file erXos added to the
    # tree: its own header is its attribution, so it takes the licence and
    # notices of erXos's other code, not the import's, and the status of the
    # tree it lives in. A catalog may hold a file captured after the tree's
    # check, so the notice is read here from the hashed bytes; a file with
    # neither row nor notice has no licence to record.
    def imported_item(origin_root, path, bytes:, label:, audited:)
      inventory = @catalog.find_import(origin_root)
      raise Error, 'import source is absent from its checked catalog' unless inventory || audited
      relative = path.delete_prefix(origin_root + '/')
      item = (inventory && (inventory.fetch('changes')[relative] || inventory.fetch('files')[relative])) || audited
      raise Error, "unresolved imported input: #{label}" unless item || Attribution.erxos_addition?(bytes)
      item
    end

    def notice_reference(reference)
      canonical = authorized_path(reference.fetch('path'), expected: reference.fetch('sha256'))
      label = if canonical.start_with?(@root + '/')
                canonical.delete_prefix(@root + '/')
              else
                "external-notice/#{reference.fetch('sha256')}/#{File.basename(canonical)}"
              end
      { 'path' => label.freeze, 'sha256' => reference.fetch('sha256').dup.freeze }.freeze
    end

    def find_origin(directory)
      while directory.start_with?(@root + '/') || directory == @root
        return directory if File.file?(File.join(directory, 'ORIGIN.md'))
        break if directory == @root
        directory = File.dirname(directory)
      end
      nil
    end

    def checked_file(reference)
      exact_keys(reference, %w[path sha256])
      expected = reference.fetch('sha256')
      unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/)
        raise Error, 'invalid receipt SHA-256'
      end
      path = authorized_path(reference.fetch('path'), expected: expected)
      if @verified.key?(path)
        raise Error, "conflicting receipt input hash: #{path}" unless @verified.fetch(path) == expected
        return { 'path' => path, 'sha256' => expected }.freeze
      end
      @verified_bytes += @catalog.entry(path).fetch('size')
      raise Error, 'provenance input closure exceeds host budget' if @verified_bytes > 1024 * 1024 * 1024
      @catalog.verify(path)
      @verified[path] = expected
      { 'path' => path, 'sha256' => expected }.freeze
    end

    # Every parser/rendering consumer gets this immutable snapshot, whose own
    # bytes satisfy the expected digest. A pathname check followed by a separate
    # read cannot establish that property when an input is replaced.
    def verified_read(reference, maximum: MAX_METADATA)
      file = checked_file(reference)
      snapshot_bytes(file.fetch('path'), expected: file.fetch('sha256'), maximum: maximum)
    end

    def snapshot_bytes(path, expected: nil, maximum: MAX_METADATA)
      path = authorized_path(path, expected: expected)
      expected ||= @registered_paths[path]
      bytes = @metadata[path] ||= bounded_read(path, maximum: maximum).freeze
      raise Error, 'receipt metadata exceeds its bound' if bytes.bytesize > maximum
      if expected && Digest::SHA256.hexdigest(bytes) != expected
        raise Error, "consumed provenance bytes differ from their hash: #{path}"
      end
      bytes
    end

    def bounded_read(path, maximum: MAX_METADATA)
      path = authorized_path(path)
      @catalog.read(path, maximum: maximum)
    end

    def retain_notice(parts)
      size = parts.sum(&:bytesize)
      raise Error, 'provenance notice exceeds host budget' if size > @notice_limit
      digest = parts.each_with_object(Digest::SHA256.new) { |part, state| state.update(part) }.hexdigest
      return @notice_documents.fetch(digest) if @notice_documents.key?(digest)
      raise Error, 'provenance notices exceed host budget' if size > @notice_limit - @notice_bytes
      @notice_bytes += size
      @notice_documents[digest] = parts.join.b.freeze
    end

    def exact_keys(value, fields)
      unless value.is_a?(Hash) && value.keys.sort == fields.sort
        raise Error, 'invalid receipt fields'
      end
    end

    def path_value(value)
      unless value.is_a?(String) && value.bytesize.between?(1, 4096) && !value.include?("\0")
        raise Error, 'invalid receipt filesystem path'
      end
      value
    end

    # Receipt fields describe inputs; they never grant access to new roots.
    # Resolve links before opening or hashing, then use only this canonical path.
    def authorized_path(value, expected: nil)
      canonical = @catalog.authorize(File.expand_path(path_value(value), @root), expected: expected)
      if expected && @registered_paths.key?(canonical) && @registered_paths.fetch(canonical) != expected
        raise Error, 'external build record hash differs from its registration'
      end
      canonical
    end

    def register_external(entries)
      entries.each do |entry|
        canonical = File.realpath(entry.fetch('path'))
        if @external.key?(canonical) && @external.fetch(canonical) != entry
          raise Error, 'duplicate or conflicting external source registration'
        end
        @external[canonical] = entry
        [entry, *entry.fetch('notices')].each do |file|
          path = File.realpath(File.expand_path(path_value(file.fetch('path')), @root))
          hash = file.fetch('sha256')
          unless hash.is_a?(String) && hash.match?(/\A[0-9a-f]{64}\z/) &&
                 (!@registered_paths.key?(path) || @registered_paths.fetch(path) == hash)
            raise Error, 'invalid or conflicting external file registration'
          end
          @registered_paths[path] = hash
        end
      end
      paths = entries.flat_map { |entry| [entry.fetch('path'), *entry.fetch('notices').map { |notice| notice.fetch('path') }] }
      @catalog = @catalog.merge(BuildInputs.capture(root: @root, paths: paths)) unless paths.empty?
      paths.each do |path|
        canonical = File.realpath(File.expand_path(path, @root))
        unless @catalog.entry(canonical).fetch('sha256') == @registered_paths.fetch(canonical)
          raise Error, 'external source differs from its registration'
        end
      end
    end

    def leading_notice(bytes)
      block = false
      bytes.lines.take_while do |line|
        stripped = line.lstrip
        if block
          block = !stripped.include?('*/')
          true
        elsif stripped.start_with?('/*')
          block = !stripped.include?('*/')
          true
        else
          stripped.strip.empty? || stripped.start_with?('//', '#', '%', '--', ';')
        end
      end.join
    end
  end
end
