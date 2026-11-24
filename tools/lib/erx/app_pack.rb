# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'app_package'
require_relative 'bounded_file'
require_relative 'erlang_apps'
require_relative 'elf_plan'
require_relative 'erofs_image'
require_relative 'error'
require_relative 'oracle'
require_relative 'pack_tools'
require_relative 'runner'

module Erx
  # `erx-app pack` (docs/design-packaging.md, "Building and packing"): an app's directory
  # into its package, NAME.app, with the SDK the packer runs from.
  #
  # First each application of lib/ with a src/ is compiled afresh on every pack, so no
  # source change, removal or rename and no change of the SDK goes unseen: the host's
  # stock erlc compiles every module of src/ with +deterministic against the SDK's public
  # applications into a fresh directory, which then replaces ebin/ whole, and APP.app is
  # the src/APP.app.src with its module list the modules compiled. So no beam of a removed
  # module lingers, and no host path reaches a beam the packer compiled; an application
  # without src/ enters the package as its ebin/ holds it.
  #
  # The image holds every file below the directory's bin/ and share/ and below
  # lib/APP/ebin and lib/APP/priv for each application directory APP of lib/, at the same
  # relative path, so nothing of the host's paths, owners, modes or times reaches the
  # package (Erx::ErofsImage). A name starting with '.' is left out wherever it lies, so a
  # host's own files (.DS_Store, ._NAME, editor files) never enter a package; a link or a
  # file of any other kind is refused. A program the declaration starts is someone else's
  # bytes, built outside the packer: the host build of erx_elf_plan, the one reader of
  # executable headers, plans it as the loader will, and it is never run. The salt is the image's SHA-256 and an Ed25519
  # signature depends on the key and the bytes alone, so the same sources give the same
  # package.
  #
  # Last, the file check the machine runs, erx_pkg_header:check_file/2, judges the
  # package under the signer's key before it replaces OUT/NAME.app, so the packer never
  # leaves a package the machine would refuse as malformed.
  module AppPack
    DECLARATION = 'app.txt'
    PARTS = %w[bin share].freeze
    APPLICATION_PARTS = %w[ebin priv].freeze
    # The most bytes of an application resource file.
    RESOURCE_MAX = 65_536
    ERLC_FLAGS = %w[+deterministic].freeze
    DEADLINE = 600
    # Where the packer builds erx_elf_plan for the host, under the tree it packs with.
    TOOLS_DIRECTORY = 'build/app-pack-tools'
    # The most bytes of the planner's refusal the packer reads back.
    REFUSAL_MAX = 4096

    # The SDK the packer runs from (docs/design-packaging.md, "The SDK"): its root
    # directory, and the host's stock erlc, beside which its erl lies.
    Sdk = Data.define(:root, :erlc) do
      # erx_bytes for stock OTP, ahead of every SDK application on the file check's path.
      def host_ebin = File.join(root, 'host/erlang/ebin')
      def ebins = Dir.glob(File.join(root, 'erlang/lib/*/ebin')).sort
      def erl = File.join(File.dirname(erlc), 'erl')
    end

    # The file check's expression: the package at the first plain argument under the
    # trusted key whose hex digits are the second, answering ok or the refusal.
    FILE_CHECK = '[Path, Hex] = init:get_plain_arguments(), {ok, Bytes} = file:read_file(Path), ' \
                 'Name = list_to_binary(filename:basename(Path)), ' \
                 'Authority = {signers, [{<<"packer">>, binary:decode_hex(list_to_binary(Hex))}]}, ' \
                 'case erx_pkg_header:check_file({Name, byte_size(Bytes), Bytes}, Authority) of ' \
                 '{ok, _} -> io:format("ok~n"); Refused -> io:format("~0kp~n", [Refused]) end, halt().'

    # The file check as an image's package takes it: the package at the first plain
    # argument under the hash of its own header, whose length the machine's decoder
    # reads, answering ok with the app's name, its declared memory and that hash, or the
    # refusal. The hash binds nothing here; what the check proves is that the machine
    # decodes the file whole, under the name the file is given.
    FILE_DESCRIBE = '[Path] = init:get_plain_arguments(), {ok, Bytes} = file:read_file(Path), ' \
                    'Name = list_to_binary(filename:basename(Path)), Length = byte_size(Bytes), ' \
                    'Answer = case erx_pkg_header:decode(Length, Bytes) of ' \
                    '{ok, #{header_length := Header}} -> ' \
                    'erx_pkg_header:check_file({Name, Length, Bytes}, {hash, erx_bytes:sha256(binary:part(Bytes, 0, Header))}); ' \
                    'Refused -> Refused end, ' \
                    'case Answer of {ok, #{header := #{name := App, memory := Memory, gatt := Gatt, license := License}, ' \
                    'sha256 := Sha256}} -> ' \
                    'io:format("ok ~s ~b ~s gatt=~s ~s~n", ' \
                    '[App, Memory, binary:encode_hex(Sha256, lowercase), lists:join(",", Gatt), License]); ' \
                    'Other -> io:format("~0kp~n", [Other]) end, halt().'

    # What the file check found in a package of an image: its app's name, its declared
    # memory, its header's SHA-256, which the image's package row records, the GATT
    # services it declares, and the SPDX expression it declares as its license, '' when it
    # names none.
    Described = Data.define(:name, :memory, :sha256, :gatt, :license)

    module_function

    # Packs the app in directory with sdk (Sdk), sealed by signer (Erx::AppPackage::Signer),
    # into output_directory/NAME.app, which a checked package replaces whole; returns its
    # path. runner runs erlc, erl, fsimg and the ELF planner, which compiler builds for the
    # host from the tree at root.
    def pack(directory:, sdk:, signer:, output_directory:, runner:, root: ErofsImage::ROOT, compiler: 'clang')
      directory = File.expand_path(directory)
      declaration = declaration(directory)
      compile(directory, sdk: sdk, runner: runner)
      files = image_files(directory)
      check_start(declaration.start, files)
      check_program(declaration, files, runner: runner, root: root, compiler: compiler)
      output = File.join(File.expand_path(output_directory), "#{declaration.name}.app")
      Dir.mktmpdir('.erx-app-', File.dirname(output)) do |work|
        image = ErofsImage.new(runner: runner, root: root).write(files: files, name: "app-#{declaration.name}",
                                                                 output: File.join(work, 'image'))
        staged = File.join(work, File.basename(output))
        File.open(staged, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |file|
          file.write(package(declaration, image: File.binread(image), signer: signer))
          file.fsync
        end
        check_file(staged, key: signer.public_key, sdk: sdk, runner: runner)
        File.rename(staged, output)
      end
      output
    rescue SystemCallError => error
      raise Error, "cannot write the package of #{directory}: #{error.message}"
    end

    # Compiles each application of directory's lib/ that has a src/.
    def compile(directory, sdk:, runner:)
      applications(directory).select { |application| part_kind(directory, "lib/#{application}/src") == :directory }
                             .each { |application| build(directory, application: application, sdk: sdk, runner: runner) }
    end

    # The file check under key, the one trusted signer; raises its refusal.
    def check_file(path, key:, sdk:, runner:)
      verdict = file_check(FILE_CHECK, [path, key.unpack1('H*')], sdk: sdk, runner: runner)
      raise Error, "the file check refuses #{File.basename(path)}: #{verdict}" unless verdict == 'ok'
    end

    # The file check of the package at path as an image takes it (FILE_DESCRIBE); answers
    # its Described or raises the refusal. The answer comes from a file that may be
    # someone else's, so it is read as untrusted: an app name, a decimal memory, 64
    # hexadecimal digits, GATT service names joined by commas and a license of printable
    # ASCII within pkg_license_max, or a refusal. The license is judged where the image
    # takes the package (PackProvenance's package receipt), the GATT services by the
    # manifest check (Manifest's check_packages).
    def describe(path, sdk:, runner:)
      verdict = file_check(FILE_DESCRIBE, [path], sdk: sdk, runner: runner)
      license_max = AppPackage.codec.constant('pkg_license_max')
      _, name, memory, sha256, gatt, license =
        verdict.match(/\Aok (\S+) ([0-9]{1,20}) ([0-9a-f]{64}) gatt=([a-z0-9_,-]*) ?([\x20-\x7e]{0,#{license_max}})\z/)&.to_a
      services = gatt&.split(',', -1)
      raise Error, "the file check refuses #{File.basename(path)}: #{verdict}" unless
        name && AppPackage::APPLICATION.match?(name) && services.all? { |service| AppPackage::GATT_NAME.match?(service) }

      Described.new(name: name, memory: Integer(memory, 10), sha256: [sha256].pack('H*'), gatt: services.freeze,
                    license: license)
    end

    # The answer of the host's stock erl evaluating expression, the machine's file check
    # on the SDK's applications, over arguments.
    def file_check(expression, arguments, sdk:, runner:)
      Dir.mktmpdir('erx-app-check-') do |work|
        answer = File.join(work, 'answer')
        runner.run([sdk.erl, '-noshell', '-noinput', '-boot', 'no_dot_erlang', '-pa', sdk.host_ebin, '-pz', *sdk.ebins,
                    '-eval', expression, '-extra', *arguments],
                   name: 'erx-app-file-check', deadline: DEADLINE, chdir: work, env: Oracle::CLEAN_ERLANG_ENV, stdout: answer)
        BoundedFile.read(answer, maximum: 65_536).strip
      end
    end

    def declaration(directory)
      path = File.join(directory, DECLARATION)
      raise Error, "#{DECLARATION} is not a regular file in #{directory}" unless kind(path) == :file

      AppPackage.parse_declaration(BoundedFile.read(path, maximum: AppPackage::DECLARATION_MAX), path: DECLARATION)
    end

    # A package's bytes: its header, zeros to the block boundary, its image and the image's
    # hash tree.
    def package(declaration, image:, signer:)
      block = AppPackage.block
      tree = AppPackage.image_tree(image)
      header = AppPackage.header(declaration, image_blocks: image.bytesize / block,
                                              tree_blocks: tree.bytes.bytesize / block, salt: tree.salt,
                                              root_hash: tree.root_hash, signer: signer)
      bytes = header.ljust(((header.bytesize + block - 1) / block) * block, "\0") + image + tree.bytes
      limit = AppPackage.codec.constant('pkg_bytes_max')
      raise Error, "the package of #{declaration.name} is over #{limit} bytes" if bytes.bytesize > limit

      bytes
    end

    # Each path the image holds mapped to the host file under directory that holds it.
    def image_files(directory)
      (PARTS + application_parts(directory)).flat_map { |part| files_below(directory, part) }.to_h
    end

    # Refuses a start the image cannot serve: an application without its resource file,
    # or a program that is not a file of the image.
    def check_start(start, files)
      wanted = case start
               in AppPackage::Applications(names:) then names.map { |name| "lib/#{name}/ebin/#{name}.app" }
               in AppPackage::Program(path:) then [path]
               end
      missing = wanted.reject { |path| files.key?(path) }
      raise Error, "the app's directory has no #{missing.join(', ')}" unless missing.empty?
    end

    # Refuses a program the loader would refuse (docs/design-packaging.md, "Building and
    # packing"): erx_elf_plan's host build (Erx::ElfPlanner) plans the file for the ABI's
    # version and the target's architecture, with the app's declared memory as the most its
    # image may take. An app that starts applications has no program to plan.
    def check_program(declaration, files, runner:, root:, compiler:)
      return unless declaration.start in AppPackage::Program(path:)

      helper = PackTools.build(root: root, owner_root: root, directory: File.join(root, TOOLS_DIRECTORY), runner: runner,
                               compiler: compiler, tools: ['planner']).fetch('planner')
      begin
        ElfPlanner.new(helper: helper, runner: runner, codec: AppPackage.codec).call(files.fetch(path), budget: declaration.memory)
      rescue CommandError => error
        raise Error, "#{path} is not a program the loader accepts: #{planner_refusal(error.result)}"
      end
    end

    # The planner's reason and byte offset from its log, 'error REASON OFFSET', or its state
    # when it gave none (a deadline, a crash).
    def planner_refusal(result)
      found = BoundedFile.read(result.fetch('log'), maximum: REFUSAL_MAX).match(/\Aerror ([a-z_]{1,64}) ([0-9]{1,20})\n?\z/)
      found ? "#{found[1]} at byte #{found[2]}" : "the planner #{result.fetch('state')}"
    end

    # The parts below lib/: ebin and priv of each application directory.
    def application_parts(directory)
      applications(directory).flat_map { |application| APPLICATION_PARTS.map { |part| "lib/#{application}/#{part}" } }
    end

    # The names of lib/'s application directories, each refused unless it is one.
    def applications(directory)
      return [] unless part_kind(directory, 'lib') == :directory

      names = visible(File.join(directory, 'lib'))
      names.reject { |name| AppPackage::APPLICATION.match?(name) && kind(File.join(directory, 'lib', name)) == :directory }
           .each { |name| raise Error, "lib/#{name} is not an application directory" }
      names
    end

    # Compiles application into a fresh directory that replaces its ebin/.
    def build(directory, application:, sdk:, runner:)
      relative = "lib/#{application}"
      home = File.join(directory, relative)
      sources = files_below(directory, "#{relative}/src").map(&:last)
      resource = sources.find { |host| File.basename(host) == "#{application}.app.src" } or
        raise Error, "#{relative}/src has no #{application}.app.src"
      modules = sources.select { |host| host.end_with?('.erl') }.sort
      include = part_kind(directory, "#{relative}/include") == :directory ? ['-I', File.join(home, 'include')] : []
      work = Dir.mktmpdir('.ebin-', home)
      begin
        # Stock erlc shortens a source path by its working directory as a string prefix
        # (compile.erl's shorten_filename/1), so it runs from a parent of its sources.
        runner.run([sdk.erlc, *ERLC_FLAGS, '-o', work, '-pa', work, *sdk.ebins.flat_map { |ebin| ['-pa', ebin] }, *include, *modules],
                   name: "erlc-#{application.tr('_', '-')}", deadline: DEADLINE, chdir: directory,
                   env: Oracle::CLEAN_ERLANG_ENV)
        File.write(File.join(work, "#{application}.app"),
                   ErlangApps.with_modules(BoundedFile.read(resource, maximum: RESOURCE_MAX),
                                           modules.map { |host| File.basename(host, '.erl') }))
        FileUtils.rm_rf(File.join(home, 'ebin'))
        File.rename(work, File.join(home, 'ebin'))
      ensure
        FileUtils.rm_rf(work)
      end
    end

    # [relative path, host path] of each file below part, which is a directory or absent,
    # walked without recursion.
    def files_below(directory, part)
      return [] unless part_kind(directory, part) == :directory

      pending = [part]
      found = []
      until pending.empty?
        relative = pending.pop
        host = File.join(directory, relative)
        case kind(host)
        when :directory then pending.concat(visible(host).map { |name| "#{relative}/#{name}" })
        when :file then found << [relative, host]
        end
      end
      found
    end

    def part_kind(directory, part)
      kind(File.join(directory, part)).tap do |found|
        raise Error, "#{part} is not a directory" if found == :file
      end
    end

    # A directory's names but those starting with '.', sorted.
    def visible(directory) = Dir.children(directory).reject { |name| name.start_with?('.') }.sort

    # :file, :directory or :absent for path, which is not followed if a link; a link or
    # any other kind of file raises the refusal.
    def kind(path)
      stat = File.lstat(path)
      return :directory if stat.directory?
      return :file if stat.file?

      raise Error, "#{path} is #{stat.symlink? ? 'a link' : 'neither a regular file nor a directory'}; a package holds neither"
    rescue Errno::ENOENT
      :absent
    end

    private_class_method :file_check, :planner_refusal, :application_parts, :applications, :build, :files_below, :part_kind, :visible, :kind
  end
end
