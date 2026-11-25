# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'pack_provenance'
require_relative 'dependency_status'
require_relative 'fiasco_parts'
require_relative 'runner'
require_relative 'bounded_file'
require_relative 'toolchain_provenance'
require_relative 'archive_member'
require_relative 'fiasco_inputs'
require_relative 'build_inputs'
require_relative 'core_archive'
require_relative 'fiasco_toolchain'
require_relative 'host_path'
require_relative 'build_kind'
require_relative 'license_check'

module Erx
  # Audits the inherited build's recorded evidence. This is an evidence report,
  # missing source records prevent a successful build record.
  class FiascoProvenance
    PARTS = FiascoParts::NAMES
    # The executables QEMU virt's boot image packs beside its kernel, under build/fiasco;
    # a board with a bootstrap of its own (Fiasco::BOARD_BOOTSTRAPS) carries that one instead. Each link's inputs are the
    # list LLD's --trace printed for it, which the link rule keeps beside the
    # executable as NAME.inputs (Makerules.KERNEL, mk/prog.mk).
    USER_EXECUTABLES = {
      'bootstrap' => 'users/pkg/bootstrap/server/src/OBJ-arm64_armv8a-nofpu-plain/bootstrap.elf',
      'sigma0' => 'users/pkg/l4re-core/sigma0/server/src/OBJ-arm64_armv8a-std-l4f/sigma0'
    }.freeze

    # The header line that attributes an erXos source. A file added to a fork
    # part must also pass Attribution.erxos_addition?, as Origin#check requires.
    ERXOS_NOTICE = Attribution::ERXOS_NOTICE
    ERXOS_HEADER_LINES = 8

    # The reviewed generated files of the development build's link closure: the
    # recipes they are made from and, in its development section, how each is
    # made and the hashes of the outputs and build inputs that hold it. A
    # release kernel's generated files are made by the same rules; its audit
    # reads the section's kernel entries in its own directory, unpinned.
    GENERATION_PROFILE = 'config/provenance/fiasco-generation.json'
    GENERATION_KEYS = %w[compile_dependencies image inputs profiles].freeze

    # How the audit of one build kind runs. kernel is the kernel directory it
    # reads (Fiasco.kernel_directory); every kind also reads the users' executables
    # (USER_EXECUTABLES), their staged sources and archive record, so a release's
    # gate covers every executable its boot image carries. image is whether it also
    # reads the image the development build packed. pinned is
    # whether the audit compares the generated files, and the host tools and
    # configuration that made them, with the generation profile's hashes. Those
    # bytes come from the host's tools, so a difference is recorded in the
    # report (host_generated) rather than refused. check is what the audit
    # must establish (certify): :receipt, the development build's receipt for
    # its image, or :permissive, a release kernel's license gate
    # (check_permissive). distribution is the report's statement of where the
    # build may go, nil for a release kernel, whose gate decides that.
    # boards are the boards whose own bootstrap (Fiasco::BOARD_BOOTSTRAPS) the audit
    # also reads: a release's gate reads every one, which build_release_kernel builds
    # first; a development build makes them only when an image for the board is packed.
    Plan = Data.define(:kind, :kernel, :image, :pinned, :check, :distribution, :boards)

    def self.plan(root:, kind:)
      require_relative 'fiasco'
      kernel = Fiasco.kernel_directory(root: root, kind: kind)
      if BuildKind.development?(kind)
        Plan.new(kind: kind, kernel: kernel, image: true, pinned: true, check: :receipt,
                 distribution: 'project-only: Fiasco with parts that are not permissive', boards: [])
      else
        Plan.new(kind: kind, kernel: kernel, image: false, pinned: false, check: :permissive, distribution: nil,
                 boards: Fiasco::BOARD_BOOTSTRAPS.keys)
      end
    end

    # What a release kernel that passed its gate leaves beside itself.
    PASS_RECORD = 'license-check.json'

    # The linked sources a build of build_kind may not carry, each with its
    # license or 'no license'. A source with a license passes as the image check
    # passes an input (LicenseCheck.passes?): under its status, its public
    # label (registered gives an external registration's, by its report path, and
    # an imported source's is its original source) and where the build read it. A record
    # without a license passes only as configuration, which carries no code, or
    # as a file made from records the closure holds (ancestry), each of which is
    # checked as a source of its own.
    def self.non_permissive(sources, build_kind:, registered:)
      recorded = sources.to_h { |source| [source.fetch('path'), source] }
      sources.filter_map do |source|
        path = source.fetch('path')
        license = source['license']
        if license
          label = registered.fetch(path) { source.fetch('original_source', path) }
          read_from = source.fetch('source', path)
          next if LicenseCheck.passes?(license, status: source['status'], label:, path: read_from, build_kind:)

          [path, license]
        elsif source['role'] != 'configuration'
          made_from = ancestry(source)
          next if !made_from.empty? && made_from.all? { |ancestor| recorded.key?(ancestor) && recorded.fetch(ancestor)['state'] != 'unresolved' }

          [path, 'no license']
        end
      end
    end

    # The paths of the sources a record without a license is made from: a
    # module's sources (generated_from), a fixed generator's code, and the
    # sources of the objects it reads, through compound objects.
    def self.ancestry(record)
      references = record.values_at('generated_from', 'code', 'sources').compact.flatten
      references.map { |reference| reference.fetch('path') } +
        record.values_at('objects', 'components').compact.flatten.flat_map { |object| ancestry(object) }
    end

    # toolchain is the LLVM toolchain (FiascoToolchain) the build ran, which
    # the audit runs and records: the build's own when Fiasco passes it, else
    # the environment's when first needed; its llvm-ar reads the archives
    # unless archive_program names another.
    # kind is the build kind (BuildKind) whose kernel the audit reads; its
    # Plan says how.
    def initialize(root:, runner:, kind:, external: [], archive_program: nil, toolchain: nil)
      @root = File.realpath(root)
      @build = File.join(@root, 'build/fiasco')
      @plan = self.class.plan(root: @root, kind: BuildKind.fetch(kind))
      @kernel = @plan.kernel
      @runner = runner
      @toolchain = toolchain
      @archive_program = archive_program
      @archive_requested = archive_program
      @external = external.to_h { |entry| [File.realpath(entry.fetch('path')), entry] }
      @origins = {}
      @import_scopes = {}
      @hashes = {}
      @bytes = {}
      @archive_listings = {}
      @snapshot_bytes = 0
      @differences = {}
      @objects = build_objects
    end

    # The objects of the build, by the tree they are in (board_tree) and then by name.
    # A board's own bootstrap is a build of its own (Fiasco::BOARD_BOOTSTRAPS), whose
    # objects may share names and bytes with the main build's.
    def build_objects
      Dir.glob(File.join(@build, '**/*.o'))
         .group_by { |path| board_tree(path) }
         .transform_values { |paths| paths.group_by { |path| File.basename(path) } }
    end

    # The board whose own bootstrap build holds path, or nil for the main build.
    def board_tree(path)
      Fiasco::BOARD_BOOTSTRAPS.keys.find do |board|
        path.start_with?(File.join(@build, Fiasco.board_users(board)) + '/')
      end
    end

    # Each executable the audit reads, by name: its artifact and the list of its
    # link's inputs: the build kind's kernel, the users every image carries and
    # the bootstrap of each board the plan names, built in that board's own tree.
    def executable_links
      executables = { 'kernel' => File.join(@kernel, 'fiasco') }
      executables.merge!(USER_EXECUTABLES.transform_values { |path| File.join(@build, path) })
      @plan.boards.each do |board|
        bootstrap = USER_EXECUTABLES.fetch('bootstrap').delete_prefix('users/')
        executables["bootstrap-#{board}"] = File.join(@build, Fiasco.board_users(board), bootstrap)
      end
      executables.transform_values { |artifact| [artifact, "#{artifact}.inputs"] }
    end

    def audit
      @audit_complete = false
      @checked_catalog = nil
      @unresolved = []
      @sources = {}
      @origins = {}
      @import_scopes = {}
      @hashes = {}
      @bytes = {}
      @archive_listings = {}
      @snapshot_bytes = 0
      @differences = {}
      @objects = build_objects
      load_build_inputs
      load_generation_profiles
      archive_tool = tool_identity(@archive_requested || toolchain.program('ar'), role: 'archive')
      @archive_program = archive_tool.fetch('path')
      executables = executable_links.map do |name, (artifact, inputs)|
        audit_executable(name, artifact, inputs)
      end
      tools = [archive_tool]
      image = nil
      if @unresolved.empty?
        tools.concat(%w[gmake perl].map { |program| tool_identity(program) })
        tools.concat(toolchain.programs.map { |program| tool_identity(program, role: File.basename(program)) })
        programs = tools.to_h { |tool| [tool.fetch('program'), tool.fetch('path')] }
        @image_objcopy = programs.fetch(File.basename(toolchain.program('objcopy')))
        @image_perl = programs.fetch('perl')
        image = audit_image(executables) if @plan.image
        @bytes.each do |path, snapshot|
          unless BoundedFile.read(path, maximum: PackProvenance::MAX_METADATA) == snapshot
            raise Error, "Fiasco audit input changed: #{label(path)}"
          end
        end
      end
      @inputs.verify if @inputs
      report = { 'version' => 1, 'kind' => 'fiasco-link-audit',
        'state' => @unresolved.empty? ? 'complete' : 'blocked',
        'build_kind' => @plan.kind, 'distribution' => @plan.distribution,
        'generation_profile' => reference(@generation_profile),
        'build_inputs' => @inputs && @inputs.reference, 'host_generated' => host_generated,
        'license_notices' => license_notices,
        'tools' => tools, 'image' => image, 'executables' => executables, 'sources' => @sources.values.sort_by { |item| item.fetch('path') },
        'unresolved' => @unresolved.uniq.sort }
      report = report.except('distribution') unless @plan.distribution
      report = report.except('host_generated') unless @plan.pinned
      report.freeze
      @audit_complete = report.fetch('state') == 'complete'
      report
    rescue KeyError, Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, ArgumentError => error
      raise Error, "invalid Fiasco build records: #{error.message}"
    end

    # Refuses a kernel whose audit report is incomplete, or which links a
    # source under terms a release may not carry (non_permissive), naming
    # each such source and its license.
    def check_permissive(report)
      unless report.fetch('state') == 'complete'
        raise Error, "the kernel's link audit is incomplete: #{report.fetch('unresolved').first(3).join('; ')}"
      end
      registered = @external.to_h { |path, entry| [label(path), entry.fetch('label')] }
      refused = self.class.non_permissive(report.fetch('sources'), build_kind: @plan.kind, registered:)
      return if refused.empty?

      raise Error, 'the kernel links sources a release may not carry: ' +
                   refused.map { |path, license| "#{path} (#{license})" }.join(', ')
    end

    # Audits the build and records what its plan's check establishes: a
    # development build's receipt (record_receipt), or a release kernel's pass
    # record (certify_release). Returns the record's path.
    def certify
      case @plan.check
      in :receipt
        capture_construction
        record_receipt(audit)
      in :permissive
        certify_release
      end
    end

    def capture_construction
      require_relative 'fiasco'
      load_build_inputs
      environment = command_environment
      kernel = @kernel
      emit = lambda do |directory, output, variable, arguments|
        @runner.run(['gmake', '-C', directory, *arguments, "CROSS_COMPILE=#{FiascoToolchain::CROSS_COMPILE}", *Fiasco.host_variables,
                     '--eval=.PHONY: erx-provenance',
                     "--eval=erx-provenance: ; $(file >#{output},$(#{variable}))", 'erx-provenance'],
                    name: 'fiasco-construction', deadline: 45, env: environment)
      end
      emit.call(kernel, '.erx-vpath', 'VPATH', [])
      source = @inputs.part('kernel')
      emit.call(kernel, '.erx-bootstrap-inputs', 'OBJ_BOOTSTRAP',
                ['-f', File.join(source, 'src/Makefile.sub2'),
                 "srcdir=#{source}/src", "objbase=#{kernel}"])
      emit.call(File.join(@build, 'users/pkg/l4re-core/minimal_l4re/OBJ-arm64_armv8a-std-l4f'),
                '.erx-archive-inputs', 'OBJS_libc_minimal_l4re.a', [])
    end

    # The toolchain files a build may compile from: the resource headers of
    # the clang compiler, which runner asks that clang to locate. Each must
    # be one the reviewed LLVM profile admits.
    def self.llvm_registry(root:, compiler:, runner:)
      return [] unless compiler
      raise Error, "locating the C17 cores' clang resource headers needs a runner" unless runner

      resource = runner.run([compiler, '-print-resource-dir'], name: 'fiasco-clang-resource', deadline: 30)
      ToolchainProvenance.llvm(root: root, resource_dir: BoundedFile.read(resource.fetch('log'), maximum: 4096).strip)
    end

    def self.canonical_report(report)
      JSON.generate(report) + "\n"
    end

    def record_receipt(report)
      unless report.fetch('state') == 'complete' && report.fetch('image').fetch('artifact').fetch('path') == 'build/fiasco/images/bootstrap.raw'
        raise Error, "cannot record an incomplete Fiasco build receipt: unresolved #{report.fetch('unresolved', []).first(3).inspect}"
      end
      @inputs.verify if @inputs
      audit_path = File.join(@build, 'provenance.json')
      receipt_path = File.join(@build, 'receipt.json')
      audit_bytes = self.class.canonical_report(report)
      receipt = { 'version' => 1, 'kind' => 'fiasco', 'artifact' => report.fetch('image').fetch('artifact'),
                  'audit' => { 'path' => 'build/fiasco/provenance.json', 'sha256' => Digest::SHA256.hexdigest(audit_bytes) } }
      write_record(audit_path, audit_bytes)
      write_record(receipt_path, JSON.generate(receipt) + "\n")
      receipt_path
    end

    # Writes PASS_RECORD, naming the build kind and the bytes of every executable
    # the audit read (the kernel, the bootstraps and sigma0), once the kernel passes check_permissive. The release build
    # (Fiasco#build_release_kernel) removes the kernel and any record unless
    # this returns.
    def certify_release
      capture_construction
      report = audit
      check_permissive(report)
      executables = report.fetch('executables').to_h { |executable| [executable.fetch('name'), executable.fetch('artifact')] }
      record = File.join(@kernel, PASS_RECORD)
      write_record(record, JSON.generate({ 'version' => 1, 'kind' => 'fiasco-license-check', 'build_kind' => @plan.kind,
                                           'executables' => executables, 'state' => 'passed' }) + "\n")
      record
    end

    # Replaces path by bytes in one rename, refusing a symlink in its place.
    def write_record(path, bytes)
      raise Error, "Fiasco record destination is a symlink: #{label(path)}" if File.symlink?(path)
      Dir.mktmpdir('.receipt-', File.dirname(path)) do |directory|
        temporary = File.join(directory, 'output')
        File.binwrite(temporary, bytes)
        File.rename(temporary, path)
      end
    end

    # Permission comes from this producer's actual reads and fixed output
    # names, not from paths supplied by an artifact's JSON build record.
    def input_catalog
      raise Error, 'Fiasco source checking has not completed' unless @audit_complete && @inputs
      return @checked_catalog if @checked_catalog
      @inputs.verify
      fixed = %w[build/fiasco/receipt.json build/fiasco/provenance.json build/fiasco/images/bootstrap.raw]
      fixed << 'build/fiasco/inputs/RECORD.json'
      external_notices = @external.values.flat_map { |entry| entry.fetch('notices').map { |notice| notice.fetch('path') } }
      fixed.each { |path| read(File.join(@root, path)) }
      entries = {}
      aliases = {}
      external = external_notices.dup
      @bytes.each do |path, bytes|
        unless path.start_with?(@root + '/')
          external << path
          next
        end
        entries[path] = { 'path' => path, 'size' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes) }
        aliases[path] = path
      end
      catalog = BuildInputs.observed(root: @root, entries: entries, aliases: aliases, imports: {})
      catalog = catalog.merge(BuildInputs.pack(root: @root, paths: []))
      catalog = catalog.merge(BuildInputs.capture(root: @root, paths: external.uniq))
      PARTS.each do |part|
        scope = import_scope(part, @inputs.part(part))
        catalog = catalog.merge(scope)
      end
      @checked_catalog = catalog
    end

    # mk's fixdep output is data, never evaluated as make or shell code. Only
    # its literal source/dependency assignments and closed config wildcard are
    # accepted; the saved command is retained verbatim as evidence.
    def self.recorded_compile(bytes, object:)
      raise Error, 'compiler command record exceeds bound' if bytes.bytesize > PackProvenance::MAX_METADATA
      text = bytes.gsub(/\\\r?\n/, '')
      fields = %w[savedcmd source deps].to_h do |field|
        matches = text.scan(/^#{field}_#{Regexp.escape(object)} := ([^\n]*)$/)
        raise Error, "missing or duplicate #{field} compiler record" unless matches.size == 1
        [field, matches.first.first.strip]
      end
      dependencies = fields.fetch('deps').gsub(/\$\(wildcard \$\(OBJ_BASE\)\/include\/config\/[A-Z0-9_]+\)/, '')
      _, sources = PackProvenance.dependencies("#{object}: #{fields.fetch('source')} #{dependencies}\n")
      { 'command' => fields.fetch('savedcmd'), 'sources' => sources }.freeze
    end

    private

    def import_scope(part, part_root)
      return @import_scopes.fetch(part) if @import_scopes.key?(part)
      unless @inputs
        return @import_scopes[part] = BuildInputs.imported(root: part_root)
      end
      inventory = Origin.new(root: part_root, authorize: @inputs.method(:authorize),
        read_bytes: lambda { |path| @inputs.read(path) }, known_hash: @inputs.method(:verified_hash)).check
      observed = @inputs.observations
      prefix = part_root + '/'
      entries = observed.fetch('entries').select { |path, _entry| path.start_with?(prefix) }
      aliases = observed.fetch('aliases').select { |path, target| path.start_with?(prefix) && entries.key?(target) }
      @import_scopes[part] = BuildInputs.observed(root: part_root, entries: entries, aliases: aliases,
                                                 imports: { part_root => inventory })
    end

    def load_build_inputs
      @inputs = FiascoInputs.new(root: @root)
      @inputs.verify
    end

    def license_notices
      @sources.values.map { |source| source['license'] }.compact.uniq.each_with_object({}) do |license, result|
        identifiers = license.scan(/[A-Za-z0-9][A-Za-z0-9.+_:\-]*/)
        files = []
        files << 'fiasco/kernel/tool/preprocess/COPYING' unless (identifiers & %w[GPL-2.0-only GPL-2.0-or-later]).empty?
        files << 'config/provenance/notices/COPYING3' unless (identifiers & %w[GPL-3.0-only GPL-3.0-or-later]).empty?
        files << 'config/provenance/notices/COPYING.RUNTIME' if identifiers.include?('GCC-exception-3.1')
        result[license] = files.map { |file| reference(project_input(file)) } unless files.empty?
      end
    end

    def audit_image(executables)
      require_relative 'fiasco'
      final = File.join(@build, 'images/bootstrap.raw')
      original = read(final)
      inputs = executables.to_h { |item| [item.fetch('name'), item.fetch('artifact')] }
      Dir.mktmpdir('.image-audit-', @build) do |directory|
        linked = File.join(directory, 'bootstrap.elf')
        replayed = File.join(directory, 'bootstrap.raw')
        File.binwrite(linked, read(File.join(@root, inputs.fetch('bootstrap').fetch('path'))))
        @runner.run([@image_objcopy || toolchain.program('objcopy'), '-O', 'binary', linked, replayed],
                    name: 'fiasco-image-proof', deadline: 30, env: command_environment)
        unless BoundedFile.read(replayed, maximum: PackProvenance::MAX_METADATA) == original
          raise Error, 'final Fiasco image differs from its fixed construction replay'
        end
        { 'artifact' => reference(final), 'method' => 'byte-identical fixed construction replay',
          'inputs' => inputs.values }
      end
    end

    def load_generation_profiles
      @generation_profile = File.join(@root, GENERATION_PROFILE)
      profile = JsonInput.parse(read(@generation_profile), max_bytes: 1024 * 1024, label: 'Fiasco generation profile')
      generation = profile.is_a?(Hash) && profile[BuildKind::DEVELOPMENT]
      unless profile.is_a?(Hash) && profile.keys.sort == ['recipes', 'version', BuildKind::DEVELOPMENT].sort && profile['version'] == 1 &&
             profile['recipes'].is_a?(Hash) && profile['recipes'].size.between?(1, 8192) &&
             generation.is_a?(Hash) && generation.keys.sort == GENERATION_KEYS &&
             generation['profiles'].is_a?(Hash) && generation['profiles'].size.between?(1, 64) &&
             generation['compile_dependencies'].is_a?(Hash) &&
             generation['compile_dependencies'].size <= 64 && generation['inputs'].is_a?(Hash) && generation['inputs'].size.between?(1, 8192) &&
             generation['image'].is_a?(Hash) && generation['image'].keys.sort == %w[entry qemu_command] && generation['image']['entry'] == 'banner' &&
             generation['image']['qemu_command'].is_a?(String) && generation['image']['qemu_command'].ascii_only? &&
             !generation['image']['qemu_command'].match?(/[\x00-\x1f\x7f]/)
        raise Error, 'invalid fixed Fiasco generation profile'
      end
      generation = generation.merge('recipes' => profile.fetch('recipes'))
      check_generation_shape(generation)
      @generation = @plan.pinned ? generation : unpinned_generation(generation)
      check_recipes
      check_generation_pins if @plan.pinned
    end

    def check_generation_shape(generation)
      generation.fetch('compile_dependencies').each do |object, dependency|
        unless object.is_a?(String) && dependency.is_a?(String) && object.end_with?('.o') && dependency.end_with?('.d')
          raise Error, 'invalid fixed compiler dependency record'
        end
      end
      generation.fetch('inputs').each_value do |expected|
        unless expected.is_a?(Hash) && expected.keys.sort == %w[mode sha256] && %w[binary text].include?(expected['mode']) &&
               expected['sha256'].is_a?(String) && expected['sha256'].match?(/\A[0-9a-f]{64}\z/)
          raise Error, 'invalid fixed generation input record'
        end
      end
      generation.fetch('profiles').each_value do |profile|
        unless profile.is_a?(Hash) && profile.keys.sort == %w[code configuration metadata object_list objects output_sha256 role tools] &&
               %w[code configuration object].include?(profile['role']) && profile['output_sha256'].is_a?(String) &&
               profile['output_sha256'].match?(/\A[0-9a-f]{64}\z/) &&
               %w[code configuration metadata object_list objects tools].all? { |key| profile[key].is_a?(Array) && profile[key].size <= 4096 }
          raise Error, 'invalid fixed generation input shape'
        end
        ancestry = profile.fetch('role') == 'configuration' ? profile.fetch('configuration') :
          profile.fetch('code') + profile.fetch('objects') + profile.fetch('object_list')
        raise Error, 'fixed generation profile has no input ancestry' if ancestry.empty?
        %w[configuration metadata tools].each do |role|
          unless profile.fetch(role).all? { |path| generation.fetch('inputs').key?(path) || generation.fetch('recipes').key?(path) }
            raise Error, 'unregistered fixed generation input'
          end
        end
      end
    end

    # Each recipe's bytes, a fact about the tree that ties the profile's account
    # of a generated file to the rule that makes it, for every kind; and, when
    # the copy the users' build staged.
    def check_recipes
      @generation.fetch('recipes').each do |relative, expected|
        path = project_input(relative)
        raise Error, "stale Fiasco generation recipe: #{relative}" unless digest(path) == expected
        if relative.start_with?('fiasco/') && !relative.start_with?('fiasco/kernel/')
          part, suffix = relative.delete_prefix('fiasco/').split('/', 2)
          staged = part == 'mk' ? File.join(@build, 'source', suffix) : File.join(@build, 'source/pkg', part, suffix)
          raise Error, "stale staged Fiasco recipe: #{relative}" unless digest(staged) == expected
        end
      end
    end

    # The development build's pins: every generated file and compiler record the
    # profile names is present, and each build input whose bytes differ from the
    # recorded ones is recorded (record_difference). A release kernel's entries are read only
    # where its link closure reaches them.
    def check_generation_pins
      @generation.fetch('compile_dependencies').each do |object, dependency|
        project_input('build/fiasco/' + object)
        project_input('build/fiasco/' + dependency)
      end
      @generation.fetch('profiles').each_key { |relative| project_input('build/fiasco/' + relative) }
      @generation.fetch('inputs').each do |relative, expected|
        bytes = read(project_input(relative))
        if expected.fetch('mode') == 'text'
          raise Error, 'literal project marker in a build input' if bytes.include?('${PROJECT_ROOT}'.b)
          bytes = bytes.gsub(@root.b, '${PROJECT_ROOT}'.b)
        end
        record_difference(relative, pinned: expected.fetch('sha256'), sha256: Digest::SHA256.hexdigest(bytes))
      end
    end

    # Notes a pinned build input or generated file whose bytes on this host are
    # not the profile's: the host's tools made it, so a development build records
    # it rather than refusing (docs/design-fiasco.md, "Boot handoff").
    def record_difference(relative, pinned:, sha256:)
      @differences[relative] = { 'path' => relative, 'pinned' => pinned, 'sha256' => sha256 } unless pinned == sha256
    end

    # What differs from the pins, by path. Only a pinned audit's report holds it.
    def host_generated = @differences.values.sort_by { |difference| difference.fetch('path') }

    # The development section's entries, those for the development kernel's
    # generated files moved into this plan's kernel directory: every kernel's are
    # made by the same rules, from its own build's files, and the users' are the
    # shared build's own. Each board the plan names has the users' entries too,
    # moved into its own users build, which makes them by the same rules from its
    # own configuration. The recipes stay for the recipe check; no hash of the
    # development build holds them.
    def unpinned_generation(generation)
      kernel = Fiasco.kernel_directory(root: @root, kind: BuildKind::DEVELOPMENT).delete_prefix(@build + '/') + '/'
      profiles = generation.fetch('profiles')
      users = profiles.select { |relative, _| relative.start_with?('users/') }
      boards = @plan.boards.map { |board| moved_profiles(users, from: 'users/', to: Fiasco.board_users(board) + '/') }
      to = @kernel.delete_prefix(@build + '/') + '/'
      { 'recipes' => generation.fetch('recipes'),
        'compile_dependencies' => generation.fetch('compile_dependencies').to_h do |object, dependency|
          [moved(object, from: kernel, to: to), moved(dependency, from: kernel, to: to)]
        end,
        'profiles' => moved_profiles(profiles, from: kernel, to: to).merge(*boards) }
    end

    # A build-relative path under directory from, moved under directory to.
    def moved(relative, from:, to:) = relative.start_with?(from) ? to + relative.delete_prefix(from) : relative

    # Generation profiles, and the build inputs they name, moved from one build
    # directory to another; a project input outside the build stays.
    def moved_profiles(profiles, from:, to:)
      input = ->(path) { path.start_with?('build/fiasco/') ? 'build/fiasco/' + moved(path.delete_prefix('build/fiasco/'), from:, to:) : path }
      profiles.to_h do |relative, profile|
        [moved(relative, from:, to:), profile.to_h { |role, value| [role, value.is_a?(Array) ? value.map(&input) : value] }]
      end
    end

    def project_input(relative)
      unless relative.is_a?(String) && relative.match?(/\A[\w.\/+\-]+\z/) && !relative.start_with?('/') &&
             relative.split('/').none? { |part| %w[. ..].include?(part) }
        raise Error, 'invalid generation profile path'
      end
      selected = if @inputs && FiascoInputs::ROOTS.any? { |prefix| relative == prefix || relative.start_with?(prefix + '/') }
                   @inputs.path(relative)
                 else
                   File.join(@root, relative)
                 end
      File.realpath(selected)
    end

    def fixed_generation(path, ancestry: [])
      relative = path.delete_prefix(@build + '/')
      profile = @generation && @generation.fetch('profiles')[relative]
      return nil unless profile
      record_difference('build/fiasco/' + relative, pinned: profile.fetch('output_sha256'), sha256: digest(path)) if @plan.pinned
      record = reference(path).merge('role' => profile.fetch('role'), 'profile' => reference(@generation_profile))
      # Install the node before following header dependencies; generated layout
      # headers and their compiled type definitions can refer to each other.
      @sources[path] = record unless profile.fetch('role') == 'object'
      %w[code configuration tools metadata].each do |role|
        record[role] = profile.fetch(role).map do |input|
          file = project_input(input)
          attribute(file) if role == 'code'
          reference(file)
        end
      end
      objects = profile.fetch('objects').map { |input| project_input(input) }
      record['construction'] = profile.fetch('object_list').map do |input|
        file = project_input(input)
        _, parts = PackProvenance.dependencies("objects: #{read(file)}")
        unless parts.all? { |part| part.match?(/\A[\w.-]+\.o\z/) }
          raise Error, 'unsupported fixed transform object list'
        end
        objects.concat(parts.map { |part| File.realpath(File.join(File.dirname(file), part)) })
        reference(file)
      end
      record['objects'] = objects.map { |object| audit_object(object, ancestry: ancestry + [path]) }
      record
    end

    def tool_identity(program, role: program)
      # The name the build runs it by answers --version: a multi-call program such as
      # ld.lld, a link to lld, tells its personality by that name.
      invoked = if program.include?('/')
                  program
                else
                  HostPath.find_program(program, directories: HostPath.directories(command_environment.fetch('PATH')))
                end
      raise Error, "missing build audit tool: #{program}" unless invoked
      path = File.realpath(invoked)
      bytes = BoundedFile.read(path, maximum: PackProvenance::MAX_METADATA)
      result = @runner.run([invoked, '--version'], name: 'fiasco-audit-tool', deadline: 30, env: command_environment)
      { 'program' => role, 'path' => path, 'sha256' => Digest::SHA256.hexdigest(bytes),
        'version' => BoundedFile.read(result.fetch('log'), maximum: 1024 * 1024).lines.map(&:strip).find { |line| !line.empty? }.to_s,
        'role' => 'external build tool; no linked contribution' }
    end

    # The environment the build ran its commands in, which the audit runs its own in.
    def command_environment
      require_relative 'fiasco'
      Fiasco.build_environment
    end

    def toolchain
      @toolchain ||= FiascoToolchain.from_environment
    end

    def audit_executable(name, artifact, inputs)
      directory = File.dirname(inputs)
      contributions = PackProvenance.link_inputs(read(inputs)).map do |input|
        member = input.member
        if member
          archive_path = File.realpath(File.expand_path(input.file, directory))
          member_hash = archive_member_hash(archive_path, member: member)
          manifest = File.join(File.dirname(archive_path), '.erx-archive-inputs')
          candidates = File.file?(manifest) ? archive_objects(manifest) : @objects.fetch(board_tree(archive_path), {}).fetch(member, [])
          candidates = candidates.select { |path| File.basename(path) == member && digest(path) == member_hash }.uniq
          # Equal output bytes do not prove equal source/flag ancestry.
          if candidates.size > 1
            @unresolved << "ambiguous archive construction record: #{label(archive_path)}(#{member})"
          end
          compiles = candidates.map { |path| audit_object(path) }
          @unresolved << "archive member has no matching object: #{label(archive_path)}(#{member})" if candidates.empty?
          contribution = { 'archive' => reference(archive_path), 'member' => member, 'sha256' => member_hash, 'compiles' => compiles }
          contribution['construction'] = reference(manifest) if File.file?(manifest)
          contribution
        else
          audit_object(File.expand_path(input.file, directory))
        end
      end
      { 'name' => name, 'artifact' => reference(artifact), 'inputs' => reference(inputs), 'contributions' => contributions }
    end

    def archive_objects(manifest)
      directory = File.dirname(manifest)
      _, inputs = PackProvenance.dependencies("archive: #{read(manifest)}")
      inputs.flat_map do |input|
        path = File.realpath(File.expand_path(input, directory))
        if path.end_with?('.ofl')
          _, objects = PackProvenance.dependencies("archive: #{read(path)}")
          objects.map { |object| File.realpath(File.expand_path(object, directory)) }
        elsif path.end_with?('.o')
          [path]
        else
          raise Error, 'unsupported recorded archive construction input'
        end
      end
    end

    def archive_member_hash(path, member:)
      ArchiveMember.sha256(bytes: read(path), member: member, runner: @runner, program: @archive_program,
        owner_root: @root, directory: @build, name: 'fiasco-audit-member', environment: command_environment,
        listings: @archive_listings)
    end

    def audit_object(path, ancestry: [])
      path = File.realpath(path)
      raise Error, 'cyclic or overdeep compound object graph' if ancestry.include?(path) || ancestry.size >= 64
      external = @external[path]
      if external
        attribute(path)
        return { 'object' => reference(path), 'external' => external.fetch('label') }
      end
      directory = File.dirname(path)
      object = File.basename(path)
      command = File.join(directory, ".#{object}.cmd")
      dependencies = Dir.glob(File.join(directory, ".#{object.delete_suffix('.o')}.*.d"))
      special = @generation && @generation.fetch('compile_dependencies')[path.delete_prefix(@build + '/')]
      dependencies = [File.join(@build, special)] if special
      fixed = fixed_generation(path, ancestry: ancestry)
      return fixed if fixed
      if File.file?(command)
        key = read(command)[/^source_([^\s]+) := /, 1]
        raise Error, 'compiler record names another object' unless key && File.basename(key) == object
        record = self.class.recorded_compile(read(command), object: key)
        sources = record.fetch('sources')
        evidence = reference(command).merge('command' => record.fetch('command'))
      elsif dependencies.size == 1
        targets, sources = PackProvenance.dependencies(read(dependencies.first))
        raise Error, 'dependency does not name compiled object' unless targets.include?(object)
        evidence = reference(dependencies.first)
      elsif object == 'jdb_compound.o' && File.file?(File.join(directory, '.jdb_compound.o.deps'))
        parts = read(File.join(directory, '.jdb_compound.o.deps')).split
        raise Error, 'unsupported compound object list' unless parts.all? { |part| part.match?(/\A[\w.-]+\.o\z/) }
        return { 'object' => reference(path), 'components' => parts.map do |part|
          audit_object(File.join(directory, part), ancestry: ancestry + [path])
        end }
      else
        @unresolved << "object has no compiler dependency record: #{label(path)}"
        return { 'object' => reference(path), 'state' => 'unresolved' }
      end
      source_refs = sources.map do |source|
        file = File.realpath(File.expand_path(source, directory))
        attribute(file)
        reference(file)
      end
      { 'object' => reference(path), 'record' => evidence, 'sources' => source_refs }
    end

    def attribute(path)
      return if @sources.key?(path)
      authoritative = authoritative_path(path)
      if authoritative
        part, source = authoritative
        part_root = @inputs ? @inputs.part(part) : File.join(@root, 'fiasco', part)
        scope = import_scope(part, part_root)
        inventory = @origins[part] ||= scope.find_import(part_root)
        relative = source.delete_prefix(part_root + '/')
        item = inventory.fetch('changes')[relative] || inventory.fetch('files')[relative] || erxos_addition(source)
        raise Error, "missing imported provenance: #{label(source)}" unless item
        raise Error, "derived source differs from its origin: #{label(path)}" unless digest(source) == digest(path)
        @sources[path] = reference(path).merge('origin' => reference(File.join(part_root, 'ORIGIN.md')),
                                              'source' => label(source), 'original_source' => "fiasco/#{part}/#{relative}", 'license' => item.fetch('license'),
                                              'evidence' => item.fetch('evidence'), 'status' => FiascoParts.status(part))
        if part == 'l4re-core' && relative.start_with?('libc/musl/contrib/musl/')
          logical = 'fiasco/l4re-core/libc/musl/contrib/musl/COPYRIGHT'
          notice = project_input(logical)
          unless digest(notice) == @generation.fetch('recipes').fetch(logical)
            raise Error, 'changed embedded musl package notice'
          end
          @sources[path]['notices'] = [reference(notice)]
        end
      elsif @external.key?(path)
        item = @external.fetch(path)
        raise Error, 'external compiler input changed' unless digest(path) == item.fetch('sha256')
        @sources[path] = reference(path).merge('license' => item.fetch('license'), 'evidence' => item.fetch('evidence'),
                                              'status' => item.fetch('status'), 'notices' => item.fetch('notices'))
      elsif (captured = erxos_source(path))
        attribute_erxos(path, captured: captured)
      elsif path.start_with?(File.join(@kernel, 'auto/'))
        attribute_kernel_generated(path)
      elsif fixed_generation(path)
        # The fixed profile records input-code ancestry without inventing a
        # license for configuration values or generator-only implementation.
      else
        @sources[path] = reference(path).merge('state' => 'unresolved')
        @unresolved << "source has no origin or generator source record: #{label(path)}"
      end
    end

    # A file erXos added to a fork part, which no import record lists: its
    # header names its license, by the same test Origin#check applies to it.
    def erxos_addition(source)
      return nil unless Attribution.erxos_addition?(read(source))

      { 'license' => Attribution::ERXOS_LICENSE, 'evidence' => "erXos addition; #{ERXOS_NOTICE} in its header" }
    end

    # The captured erXos source behind path: a C17 core, a boot archive's
    # liberx source, a header or a stack-proof declaration of the private
    # inputs, or either cores'
    # archive's copy of the seam's headers (CoreArchive.seam_headers). nil for
    # any other path.
    def erxos_source(path)
      return nil unless @inputs

      seam = %w[cores boot-cores].map { |name| File.join(@build, name, CoreArchive::SEAM) + '/' }
                                 .find { |directory| path.start_with?(directory) }
      if seam
        # The seam holds erx/core/NAME.h, each copied from its seam header.
        origin = CoreArchive.seam_headers(@inputs.tree)[path.delete_prefix(seam).delete_prefix('erx/core/')]
        return nil unless origin

        captured = @inputs.path(origin)
      else
        captured = path
      end
      tree = @inputs.tree + '/'
      relative = captured.delete_prefix(tree)
      return nil unless captured.start_with?(tree) &&
                        FiascoInputs::ERXOS_ROOTS.any? { |root| relative == root || relative.start_with?(root + '/') }

      captured
    end

    def attribute_erxos(path, captured:)
      relative = captured.delete_prefix(@inputs.tree + '/')
      attribution = imported_attribution(captured) || erxos_attribution(captured)
      unless attribution
        @sources[path] = reference(path).merge('state' => 'unresolved')
        @unresolved << "erXos source has no #{ERXOS_NOTICE} header: #{relative}"
        return
      end
      raise Error, "derived source differs from its origin: #{label(path)}" unless digest(captured) == digest(path)

      @sources[path] = reference(path).merge('source' => label(captured), 'original_source' => relative, **attribution)
    end

    # Imported code in the tree, such as BLAKE3, carries no erXos notice: its
    # license and evidence are its row in the ORIGIN.md beside it. nil for a file
    # with no row, even beside an ORIGIN.md, so an erXos file there still needs
    # its notice.
    def imported_attribution(captured)
      directory = File.dirname(captured)
      return nil unless File.file?(File.join(directory, 'ORIGIN.md'))

      row = Origin.new(root: directory, read_bytes: ->(path) { @inputs.read(path) }).imported_file(File.basename(captured))
      row && { 'license' => row.fetch('license'), 'evidence' => row.fetch('evidence'), 'status' => 'imported' }
    end

    def erxos_attribution(captured)
      return nil unless erxos_notice?(captured)

      { 'license' => 'BSD-2-Clause', 'evidence' => "erXos source; #{ERXOS_NOTICE} in its header", 'status' => 'erxos' }
    end

    def erxos_notice?(path)
      read(path).each_line.first(ERXOS_HEADER_LINES).any? { |line| line.include?(ERXOS_NOTICE) }
    end

    def attribute_kernel_generated(path)
      relative = path.delete_prefix(@kernel + '/')
      graph = File.join(@kernel, '.Modules.deps')
      lines = read(graph).lines
      output = module_rule(lines, target: relative)
      stamp = output && output.split(':', 2).last.split.first
      rule = stamp && module_rule(lines, target: stamp)
      names = rule && rule.split(':', 2).last.split
      vpath = File.join(@kernel, '.erx-vpath')
      directories = File.file?(vpath) ? read(vpath).split : []
      source_root = @inputs ? File.join(@inputs.part('kernel'), 'src') : File.join(@root, 'fiasco/kernel/src')
      unless directories.all? { |directory| directory.match?(/\A[\w\/-]+\z/) && !directory.split('/').include?('..') && !directory.start_with?('/') }
        raise Error, 'unsupported recorded kernel source search path'
      end
      originals = names && names.map do |name|
        raise Error, 'unsupported module source name' unless name.match?(/\A[\w.-]+\.cpp\z/)
        directories.map { |directory| File.join(source_root, directory, name) }.find { |source| File.file?(source) }
      end
      if names && !names.empty? && names.uniq.size == names.size && originals.none?(&:nil?)
        @sources[path] = reference(path).merge('generated_from' => originals.map { |source| reference(source) },
                                              'graph' => reference(graph), 'search_path' => reference(vpath))
        originals.each { |source| attribute(source) }
      else
        @sources[path] = reference(path).merge('state' => 'unresolved')
        @unresolved << "generated source has no unambiguous module source record: #{label(path)}"
      end
    end

    def module_rule(lines, target:)
      rules = lines.select { |line| line.include?(':') && line.split(':', 2).first.split.include?(target) }
      rules.size == 1 ? rules.first : nil
    end

    def authoritative_path(path)
      PARTS.each do |part|
        prefix = File.join(@root, 'fiasco', part) + '/'
        captured = @inputs ? @inputs.part(part) + '/' : prefix
        return [part, path] if path.start_with?(captured)
        if path.start_with?(prefix)
          raise Error, 'compiled Fiasco source refers to mutable repository inputs' if @inputs
          return [part, path]
        end
        derived = part == 'mk' ? File.join(@build, 'source/mk/') : File.join(@build, 'source/pkg', part) + '/'
        return [part, captured + path.delete_prefix(derived)] if path.start_with?(derived)
      end
      nil
    end

    def read(path)
      captured = @inputs && @inputs.find_captured_path(path)
      path = captured || File.realpath(path)
      unless path.start_with?(@build + '/') || path.start_with?(File.join(@root, 'config/')) || PARTS.any? { |part| path.start_with?(File.join(@root, 'fiasco', part) + '/') } || @external.key?(path)
        raise Error, "unregistered audit input: #{label(path)}"
      end
      @bytes[path] ||= begin
        bytes = captured ? @inputs.read(path, maximum: PackProvenance::MAX_METADATA) : BoundedFile.read(path, maximum: PackProvenance::MAX_METADATA)
        @snapshot_bytes += bytes.bytesize
        raise Error, 'audit input closure exceeds byte bound' if @snapshot_bytes > 512 * 1024 * 1024
        bytes
      end
    end

    def digest(path)
      @hashes[path] ||= Digest::SHA256.hexdigest(read(path))
    end

    def reference(path)
      { 'path' => label(path), 'sha256' => digest(path) }
    end

    def label(path)
      path.start_with?(@root + '/') ? path.delete_prefix(@root + '/') : path
    end
  end
end
