# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'set'
require_relative 'bounded_file'
require_relative 'chokepoint_rules'
require_relative 'device_callers'
require_relative 'dependencies'
require_relative 'device_posters'
require_relative 'pipe_makers'
require_relative 'erofs_reads'
require_relative 'web_sinks'
require_relative 'generated'
require_relative 'net_checks'
require_relative 'command_needs'
require_relative 'facet_names'
require_relative 'ns_writers'
require_relative 'origin_unwraps'
require_relative 'attach_fields'
require_relative 'origin'
require_relative 'runner'
require_relative 'source_text'

module Erx
  # Checks erXos's own sources (ASCII-only, JSON read only through JsonInput)
  # and each import's recorded provenance.
  #
  # The project's files are the ones git lists: every tracked file, and every
  # untracked file that no exclude rule (.gitignore, .git/info/exclude, the
  # user's excludes file) ignores, which is every file a plain `git add` could
  # stage. Build output, agent state and agent worktrees under .claude/ are
  # not sources because .gitignore says so; nothing here lists them. A project
  # that is not the top of a git checkout, or whose listing is empty, has no
  # such file set, so the check refuses it rather than checking nothing.
  #
  # Diagnostics carry raw names; the CLI's sink escapes them (Terminal.puts).
  class Checks
    IMPORTS = %w[
      ctaes
      display/libmemdraw
      fiasco/bootstrap
      fiasco/drivers-frst
      fiasco/kernel
      fiasco/l4re-core
      fiasco/libfdt
      fiasco/mk
      hw/svd/pl011
      kernel/crypto/blake3
      kernel/crypto/chacha20
      kernel/crypto/sha2
      littlefs
      musl
      otp
      test/oracle/common_test
      test/shell/rc/plan9port
    ].freeze
    # Git submodules: upstream trees pinned by the commit the superproject
    # records, whose text is not erXos's and is not scanned. Each records its
    # origin in an ORIGIN.md in the directory that holds it, outside the
    # submodule, which the check requires. Any other nested repository is
    # refused.
    SUBMODULES = %w[
      display/lvgl/lvgl
    ].freeze
    LISTING_BYTES = 64 * 1024 * 1024
    LISTING_DEADLINE = 120
    LISTED_NAME = /\A[^\x00-\x1f\x7f]+\z/
    # Host tooling reads JSON only through JsonInput, which bounds size and
    # depth and refuses duplicate keys; any other parse would bypass those.
    # Rather than list json's many ways to parse, the check allows the two
    # ways to write: outside JsonInput, the only JSON member calls a Ruby
    # source under tools/ may make are JSON.generate and JSON.pretty_generate.
    # It reads lines, not Ruby, so it is a guard against an accidental parse,
    # not against an alias of the module; a comment whose prose puts a
    # parenthesis, bracket or period right after the module's name also
    # fails it, loudly.
    JSON_PARSER = 'tools/lib/erx/json_input.rb'
    JSON_OUTSIDE_WRITING = /
      \bJSON\s*(?:
        ::                                                # a constant: Parser, Coder, ParserError
        | [(\[]                                           # the Kernel method or the index method
        | \.(?!\s*(?:generate|pretty_generate)\b)         # any other member call
      )
      | [.]from_json\b                                    # json's core additions
    /x

    # ProductionImage#build adds nothing to the system release; its test entry point adds
    # test code and marks the archive (ERX_PACK_TEST_CODE). This check enforces two things
    # only: that only the QEMU harnesses that boot test code (TEST_IMAGE_BUILDERS: the
    # oracle's run, the block device, system domain and programs suites') call that entry
    # point, and that no other
    # source passes a literal true for the packer's test keyword. It does not prove that every image carrying
    # test code is marked; other packers carry unmarked test code (TODO.md). So no Ruby
    # source under tools/, except the module that defines the entry point and those
    # callers, may match TEST_IMAGE_ENTRY: the entry point's name, in a call, a symbol or
    # a comment, or a literal true for the packer's test_code keyword. The check reads
    # lines, as the JSON check does, so it catches a slip, not a name assembled from
    # pieces. Tests outside tools/ may name either.
    # block_device.rb lends its test image to driver_domains.rb (BlockDevice::Run#test_image_for).
    TEST_IMAGE_BUILDERS = %w[tools/lib/erx/oracle_qemu.rb tools/lib/erx/block_device.rb tools/lib/erx/system_domain.rb
                             tools/lib/erx/programs.rb].freeze
    TEST_IMAGE_DEFINER = 'tools/lib/erx/production_image.rb'
    TEST_IMAGE_ENTRY = /\bbuild_test_image\b|\btest_code:\s*true\b/

    # Unsets every GIT_ variable of the caller's environment, for a git child
    # that must act on the repository it names and on nothing else.
    def self.isolated_git_environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }

    # Decides what the log of `git ls-files -z` says: the sorted, distinct
    # names it lists, or a refusal. git ends each name with NUL and shares the
    # log with its warnings, which end in a newline. Every name must be valid
    # UTF-8 with no C0 control or DEL character, and the log must end in NUL,
    # so no git warning (an unreadable directory it skipped, for one) passes
    # as names; a tracked name holding such a character is refused with it.
    # Unmerged entries repeat a name, once per stage.
    def self.listed_names(bytes, log:)
      raise Error, "git listed no project files; log: #{log}" if bytes.empty?
      names = bytes.split("\0").map { |name| name.force_encoding(Encoding::UTF_8) }
      unless bytes.end_with?("\0") && names.all? { |name| name.valid_encoding? && LISTED_NAME.match?(name) }
        raise Error, "git reported a problem while listing sources, or listed a name that is not " \
                     "printable UTF-8; log: #{log}"
      end
      names.uniq.sort.freeze
    end

    # generators: what Generated.ensure computes the generated tree with,
    # whose files the chokepoint rules read beside the listed ones.
    def initialize(root:, runner:, required_imports: IMPORTS, chokepoints: ChokepointRules::ALL,
                   generators: Generated::GENERATORS, submodules: SUBMODULES)
      @root = File.expand_path(root)
      @runner = runner
      @required_imports = required_imports
      @chokepoints = chokepoints
      @generators = generators
      @submodules = submodules
    end

    def run
      @required_imports.each do |relative|
        path = File.join(@root, relative)
        marker = File.join(path, 'ORIGIN.md')
        unless File.directory?(path) && File.file?(marker) && !File.symlink?(path) && !File.symlink?(marker)
          raise Error, "missing imported source provenance: #{relative}/ORIGIN.md"
        end
        Origin.new(root: path).check
      end
      @submodules.each do |relative|
        marker = File.join(@root, File.dirname(relative), 'ORIGIN.md')
        next if File.file?(marker) && !File.symlink?(marker)

        raise Error, "missing submodule provenance: #{File.dirname(relative)}/ORIGIN.md"
      end
      listed = project_files.reject { |name| @submodules.include?(name) }
      listed_set = listed.to_set
      own_sources = listed.reject { |relative| imported?(relative) }
      own_sources.each { |relative| check_own_source(relative, listed: listed_set) }
      check_json_parsing(own_sources)
      check_test_image_builders(own_sources)
      check_device_callers(listed)
      check_device_posters(listed)
      check_pipe_makers(listed)
      check_erofs_reads(listed)
      check_net(listed)
      check_command_needs(listed)
      check_facet_names(listed)
      check_web_sinks(listed)
      check_ns_writers(listed)
      check_origin_unwraps(listed)
      check_attach_fields(listed)
      # The chokepoint rules read the same listing, imports included, since
      # the glue lives inside the stopgap kernel's imported tree; an import
      # below kernel/ they read as erXos's own C (chokepoint_upstream?).
      # They read the generated tree too, each file under the path it
      # mirrors, so a rule's scope and sites hold for a generated file as for
      # a tracked one, and no generated file escapes them by living in the
      # build tree. Generated.ensure refuses a file of the tree at a
      # generated file's path, so no listed file shares a name with one.
      generated = generated_sources
      Chokepoints.enforce(@chokepoints, root: @root, names: (listed | generated.keys).sort,
                                        imported: method(:chokepoint_upstream?), sources: generated)
      true
    end

    private

    # Lists the project's files with git (see the class comment), relative to
    # the root. Nested repositories appear with a trailing slash.
    def project_files
      git = File.join(@root, '.git')
      unless File.directory?(git) || File.file?(git)
        raise Error, "the source check lists its files with git, and #{@root} is not the top of a git checkout"
      end
      # --git-dir and --work-tree name the checkout and no GIT_ variable of the
      # caller's environment reaches git, so the repository, work tree and
      # index are the checkout's own; the user's and system git config and the
      # user's excludes file still apply. ls-files runs no hook, filter or
      # pager; the one configured program it would start is core.fsmonitor,
      # which -c turns off.
      result = begin
        @runner.run(['git', '-c', 'core.fsmonitor=false', "--git-dir=#{git}", "--work-tree=#{@root}",
                     'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                    name: 'list-own-sources', deadline: LISTING_DEADLINE, chdir: @root,
                    env: self.class.isolated_git_environment,
                    output_limit: LISTING_BYTES)
      rescue CommandError => error
        raise Error, "git could not list the project's files; log: #{error.result.fetch('log')}"
      end
      listing = BoundedFile.read(result.fetch('log'), maximum: LISTING_BYTES)
      self.class.listed_names(listing, log: result.fetch('log'))
    end

    def imported?(relative)
      @required_imports.any? { |import| relative == import || relative.start_with?(import + '/') }
    end

    # Each generated file's mirrored path => its root-relative path in the
    # generated tree, brought up to date first. The stamp is not a file
    # the tree mirrors, and the glob does not list it.
    def generated_sources
      output = Generated.ensure(root: @root, generators: @generators).output
      Dir.glob('**/*', base: output).sort.select { |relative| File.file?(File.join(output, relative)) }
         .to_h { |relative| [relative, File.join(Generated::OUTPUT, relative)] }
    end

    # What the chokepoint rules treat as upstream code. An import below
    # kernel/ (kernel/crypto/*) is compiled into the cores' archive and linked
    # into the kernel as kernel/core is, so every rule over erXos's own C
    # reads it too.
    # musl's erxos directories are erXos's own code in an import's tree, so those rules read them too.
    def chokepoint_upstream?(relative)
      imported?(relative) && !relative.start_with?('kernel/') && !relative.match?(%r{\Amusl/(?:arch|src/[^/]+)/erxos/})
    end

    # A listed name must reach, through no directory alias, a regular file or
    # a link to another listed regular file. A tracked file deleted from the
    # checkout has no bytes to check.
    def check_own_source(name, listed:)
      relative = name.delete_suffix('/')
      stat = find_stat(relative)
      return if stat.nil?
      parent = File.dirname(relative)
      expected_parent = parent == '.' ? canonical_root : File.join(canonical_root, parent)
      unless File.realpath(File.join(@root, parent)) == expected_parent
        raise Error, "own source directory aliases are unsupported: #{parent}"
      end
      if stat.symlink?
        check_link(relative, listed: listed)
      elsif stat.directory?
        raise Error, "listed directory (a nested repository, a submodule, or a tracked file replaced by a " \
                     "directory) is unsupported in the source tree: #{relative}"
      elsif stat.file?
        check_ascii(relative)
      else
        raise Error, "special file in source tree: #{relative}"
      end
    end

    # Returns the entry's own status, or nil when nothing is at the path.
    def find_stat(relative)
      File.lstat(File.join(@root, relative))
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    # A link's target must be a regular file that git lists too, so the check
    # never reads build output, private state or a device through a link.
    def check_link(relative, listed:)
      path = File.join(@root, relative)
      begin
        target = File.realpath(path)
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise Error, "unresolved source link: #{relative}"
      end
      raise Error, "source link leaves the project: #{relative}" unless target.start_with?(canonical_root + '/')
      raise Error, "own source directory aliases are unsupported: #{relative}" if File.directory?(target)
      unless File.file?(target) && listed.include?(target.delete_prefix(canonical_root + '/'))
        raise Error, "source link names no listed project file: #{relative}"
      end
      check_ascii(relative)
    end

    def canonical_root
      @canonical_root ||= File.realpath(@root)
    end

    def check_json_parsing(own_sources)
      own_sources.each do |relative_path|
        next unless relative_path.start_with?('tools/')
        path = File.join(@root, relative_path)
        next if relative_path == JSON_PARSER || !ruby_source?(path)
        File.binread(path).each_line.with_index(1) do |line, number|
          next unless JSON_OUTSIDE_WRITING.match?(line)
          raise Error, "JSON used other than to write, outside #{JSON_PARSER}: #{relative_path}:#{number}"
        end
      end
    end

    # Imports included: prim_file and kernel are imports, and a write from either counts.
    def check_ns_writers(listed)
      sources = listed.select { |relative| NsWriters.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = NsWriters.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # Imports included: OTP is imported, and a stock module edited to take the envelope
    # apart is the violation the check exists for.
    def check_origin_unwraps(listed)
      sources = listed.select { |relative| OriginUnwraps.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = OriginUnwraps.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # Every attachment field of an object record has its insert and its walk
    # in the teardown (AttachFields).
    def check_attach_fields(listed)
      sources = listed.select { |relative| AttachFields.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = AttachFields.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    def check_test_image_builders(own_sources)
      allowed = [*TEST_IMAGE_BUILDERS, TEST_IMAGE_DEFINER]
      own_sources.each do |relative_path|
        next unless relative_path.start_with?('tools/') && !allowed.include?(relative_path)
        path = File.join(@root, relative_path)
        next unless ruby_source?(path)
        File.binread(path).each_line.with_index(1) do |line, number|
          next unless TEST_IMAGE_ENTRY.match?(line)
          raise Error, "a test image is built only by #{TEST_IMAGE_BUILDERS.join(' and ')}: #{relative_path}:#{number}"
        end
      end
    end

    # Imports included, as for the device callers.
    def check_device_posters(listed)
      sources = listed.select { |relative| DevicePosters.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = DevicePosters.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # Imports included, as for the device callers.
    def check_pipe_makers(listed)
      sources = listed.select { |relative| PipeMakers.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = PipeMakers.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # Imports included: a stock module edited to call erx_device is as much a violation.
    def check_device_callers(listed)
      sources = listed.select { |relative| DeviceCallers.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = DeviceCallers.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # Imports included: a stock module edited to read the funnel's store is as much a violation.
    def check_erofs_reads(listed)
      sources = listed.select { |relative| ErofsReads.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = ErofsReads.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # erx_net's atoms, sequence-wrap and FreeBSD notice rules, and the grant-key
    # and call-timeout rules of erx_net and its client, erx_net_client.
    def check_net(listed)
      files = listed.select { |relative| NetChecks.covers?(relative) && File.file?(File.join(@root, relative)) }
      return if files.empty?

      violations = NetChecks.violations(files.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # The web client's handwritten sources write no HTML or code sink, and
    # only hrefOf writes an href (WebSinks).
    def check_web_sinks(listed)
      sources = listed.select { |relative| WebSinks.covers?(relative) && File.file?(File.join(@root, relative)) }
      violations = WebSinks.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # A command that names a module of a service of the system domain declares the
    # service's facet, and erx_shell's other modules name none (CommandNeeds).
    def check_command_needs(listed)
      sources = listed.select { |relative| CommandNeeds.reads?(relative) && File.file?(File.join(@root, relative)) }
      violations = CommandNeeds.violations(sources.to_h { |relative| [relative, File.binread(File.join(@root, relative))] })
      raise Error, violations.join("\n") unless violations.empty?
    end

    # Every facet name the Erlang sources use is in the table of abi/services and the
    # system manifest, and each interface cites a design heading (FacetNames). A listing
    # with no Erlang source, as the tests of the other checks make, has nothing to hold.
    def check_facet_names(listed)
      return unless listed.any? { |relative| FacetNames.covers?(relative) }

      read = ->(paths) { paths.select { |relative| File.file?(File.join(@root, relative)) }
                              .to_h { |relative| [relative, File.binread(File.join(@root, relative))] } }
      files = read.call(listed.select { |relative| FacetNames.covers?(relative) || FacetNames.table_file?(relative) })
      docs = read.call(listed.select { |relative| FacetNames.design_doc?(relative) })
      violations = FacetNames.violations(files, docs: docs)
      raise Error, violations.join("\n") unless violations.empty?
    end

    def ruby_source?(path)
      File.file?(path) &&
        (File.extname(path) == '.rb' || (File.binread(path, 32) || '').start_with?('#!/usr/bin/env ruby'))
    end

    def check_ascii(relative)
      return if File.extname(relative) == '.md'
      path = File.join(@root, relative)
      prefix = File.binread(path, 2) || ''.b
      return unless SourceText.source?(relative, bytes: prefix)
      bytes = File.binread(path)
      return if bytes.ascii_only?
      line = bytes.lines.each_with_index.find { |text, _index| !text.ascii_only? }.last + 1
      raise Error, "non-ASCII erXos source: #{relative}:#{line}"
    end
  end
end
