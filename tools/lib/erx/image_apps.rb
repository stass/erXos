# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'openssl'
require_relative 'abi_source'
require_relative 'app_pack'
require_relative 'bounded_file'
require_relative 'dependency_status'
require_relative 'error'
require_relative 'license_check'
require_relative 'license_expression'
require_relative 'manifest_frontend'
require_relative 'oracle'
require_relative 'package_key'
require_relative 'runtime'
require_relative 'sdk'

module Erx
  # The packages an image builder adds to an image (docs/design-packaging.md, "Adding an
  # app to an image"), as the rows and files the image takes: for each package NAME.app,
  # the file at apps/NAME.app of the slot's system partition, never in the boot image
  # ("Where a package lies"), a `package NAME` row whose input is the package's
  # artifact and whose enable is YES only when the builder enables it, a `signer` row for
  # each key the builder names (--signer). The builder's development package key, which a
  # development image trusts, is the build context's, never a source row.
  #
  # The board's manifest source is never edited: the rows are appended to the image's
  # copy, and the manifest check (property 19's fifth clause) binds each to its artifact,
  # whose header SHA-256 the build's file check found (AppPack.describe), so a package of
  # the image is trusted by that hash whoever signed it, the builder's key included. The
  # image judges each package's license as it judges an archive's (ProductionImage's
  # package receipts), so the license the package declares decides whether it may enter:
  # one that is not permissive enters only a local test image, which the builder asks for
  # with --local and which never leaves the host that built it (Plan#status).
  module ImageApps
    # The system partition's directory of the image's packages, the root of the `system`
    # tree (erx_storage_system), so a package reaches no other path of the partition.
    PARTITION_DIRECTORY = 'apps'
    ARTIFACT_KIND = 'package'
    DEVELOPMENT_SIGNER = 'development'
    # The kiosk: the app the Raspberry Pi 4's card carries, enabled (ProductionImage#published_apps),
    # and the kiosk suite boots on QEMU virt (Kiosk), both as packed_kiosk packs it.
    KIOSK = 'examples/dashboard'
    KEY_BYTES = 32
    # The most bytes of a signer's key file; a PEM Ed25519 public key takes about 115.
    KEY_FILE_MAX = 16 * 1024

    # A package an image carries: its file, by absolute path, and what the file check
    # found in it (AppPack::Described), gatt none unless given. Its name is an app name, so
    # no name it carries spells another manifest row.
    Package = Data.define(:path, :name, :memory, :sha256, :license, :gatt) do
      def initialize(path:, name:, memory:, sha256:, license:, gatt: [].freeze)
        raise Error, "#{name.inspect} is not an app name" unless AppPackage::APPLICATION.match?(name)

        super(path: File.expand_path(path), name: name, memory: memory, sha256: sha256, license: license, gatt: gatt)
      end

      # Where the package lies in the system partition, and its artifact's name.
      def entry_path = "#{PARTITION_DIRECTORY}/#{name}.app"
      def artifact_name = "#{ARTIFACT_KIND}-#{name}"
    end

    # A key the image trusts for packages installed later: a `signer NAME` row with its
    # 32-byte Ed25519 public key. Its name is a manifest identifier, so it spells no other
    # row.
    Signer = Data.define(:name, :key) do
      def initialize(name:, key:)
        raise Error, "#{name.inspect} is not a signer name" unless Manifest::Frontend::IDENTIFIER.match?(name)
        raise Error, "signer #{name}'s key is not an Ed25519 public key" unless key.is_a?(String) && key.bytesize == KEY_BYTES

        super(name: name, key: key.b.freeze)
      end
    end

    # What the image takes for its packages, each in name order, and the manifest
    # source text appended to the board's: the package rows, then the signer rows. local
    # is the builder's --local: the image is a local test image, which takes a package
    # whose license is not permissive and is marked local in its build facts.
    Plan = Data.define(:packages, :rows, :local) do
      # The status package is registered under: package-local for a package of a local
      # image that names a license that is not permissive, which only a development
      # build accepts, and permanent for every other, whose license is judged as a
      # permanent dependency's, so such a package enters no image built without --local.
      # A package that names no license is permanent, and enters no image.
      def status(package)
        restricted = local && !package.license.empty? && !LicenseExpression.permissive?(package.license)
        restricted ? LicenseCheck::PACKAGE_LOCAL : DependencyStatus::PERMANENT
      end

      # Whether the image takes no package, no signer and is no local test image.
      def empty? = packages.empty? && rows.empty? && !local

      # Each path of the system partition mapped to the package file that lies there.
      def entries = packages.to_h { |package| [package.entry_path, package.path] }

      # Each package's artifact for the manifest check (Manifest's check_packages) by
      # name: its header's hash, which binds the row to the file the system partition
      # holds, so the artifact names no entry of the archive, and the GATT services it
      # declares, which the check holds to the apps row's gatt, none named by two packages.
      def artifacts
        packages.to_h do |package|
          [package.artifact_name, { 'kind' => ARTIFACT_KIND, 'name' => package.name, 'memory' => package.memory,
                                    'sha256' => package.sha256.unpack1('H*'), 'gatt' => package.gatt }.freeze]
        end
      end
    end

    # The kiosk as packed_kiosk packs it: its Package, the copy of KIOSK it was packed
    # from, and the AppPack::Sdk it was packed over.
    PackedKiosk = Data.define(:package, :app, :sdk)

    module_function

    # The packages of sources, each an app directory, which AppPack.pack packs with sdk
    # and signer into the directory into, building erx_elf_plan for the host with
    # compiler, or a package file, copied there as it is: the
    # image takes the copy in the build tree, which nothing else writes, so the file the
    # file check described is the file the image packs. into must be empty.
    def gather(sources, into:, sdk:, signer:, runner:, root:, compiler:)
      raise Error, "#{into} is not an empty directory" unless Dir.exist?(into) && Dir.empty?(into)

      sources.map do |source|
        path = if File.directory?(source)
                 AppPack.pack(directory: source, sdk: sdk, signer: signer, output_directory: into, runner: runner, root: root,
                                          compiler: compiler)
               else
                 copied(source, into)
               end
        read(path, sdk: sdk, runner: runner)
      end
    end

    # The packages of the app directories sources as `tools/erx pack --app` packs them:
    # the SDK exported into sdk_directory (exported_sdk), then each directory packed over
    # it and signed by signer into packages_directory (gather). Both directories must
    # exist and be empty.
    def packed_apps(sources, sdk_directory:, packages_directory:, root:, runner:, signer:, compiler:, linker:)
      gather(sources, into: packages_directory, sdk: exported_sdk(sdk_directory, root: root, runner: runner, compiler: compiler, linker: linker),
                      signer: signer, runner: runner, root: root, compiler: compiler)
    end

    # The kiosk (KIOSK) of the tree at root as the card and the kiosk suite take it, a
    # PackedKiosk, in the empty directory work: a copy of KIOSK at work/app, so the
    # packer's ebin/ never lands in the source tree, packed over the SDK the tree exports
    # under work/sdk (exported_sdk) into work/packages, and sealed by the published package
    # key (PackageKey.published), so no builder's own key enters the bytes: every builder
    # of one clean tree packs the same package (the copy takes KIOSK as it lies on disk).
    def packed_kiosk(work, root:, runner:, compiler:, linker:)
      raise Error, "#{work} is not an empty directory" unless Dir.exist?(work) && Dir.empty?(work)

      app = File.join(work, 'app')
      FileUtils.cp_r(File.join(root, KIOSK), app)
      sdk = exported_sdk(FileUtils.mkdir_p(File.join(work, 'sdk')).first, root: root, runner: runner, compiler: compiler,
                                                                   linker: linker)
      package, = gather([app], into: FileUtils.mkdir_p(File.join(work, 'packages')).first, sdk: sdk,
                               signer: PackageKey.published, runner: runner, root: root, compiler: compiler)
      PackedKiosk.new(package: package, app: app, sdk: sdk)
    end

    # The SDK the tree at root exports with stock's compiler into directory/sdk, its native
    # half built with the LLVM compiler and linker (SdkSysroot), as the AppPack::Sdk the
    # packer runs from.
    def exported_sdk(directory, root:, runner:, compiler:, linker:)
      erlc = File.join(File.dirname(Oracle.new(root: root, runner: runner).erl_path(Runtime::HOST_OTP_FLAVOUR)), 'erlc')
      exported = File.join(directory, 'sdk')
      Sdk.new(root: root, runner: runner, erlc: erlc, compiler: compiler, linker: linker).export(exported)
      AppPack::Sdk.new(root: exported, erlc: erlc)
    end

    # The package file at path as the image takes it, refused unless the machine's file
    # check decodes it whole under its own name (AppPack.describe).
    def read(path, sdk:, runner:)
      described = AppPack.describe(File.expand_path(path), sdk: sdk, runner: runner)
      Package.new(path: path, **described.to_h)
    end

    # The signer whose public key is the PEM file at path, named by the file's name
    # without its extension; a private key is refused, so none is read for a row, and
    # no passphrase is asked for. development is the builder's own key's name, which only
    # the build gives, and the published package key, whose private half anyone holds,
    # is trusted by nothing (PackageKey.published).
    def signer(path)
      name = File.basename(path, '.*')
      raise Error, "--signer #{path}: #{DEVELOPMENT_SIGNER} names the builder's own key" if name == DEVELOPMENT_SIGNER

      pem = BoundedFile.read(path, maximum: KEY_FILE_MAX)
      raise Error, "--signer #{path} is not a PEM public key" unless pem.start_with?('-----BEGIN PUBLIC KEY-----')

      key = OpenSSL::PKey.read(pem, '')
      raise Error, "--signer #{path} is not an Ed25519 public key" unless key.oid == 'ED25519'

      raise Error, "--signer #{path} is the published package key, which nothing trusts" if
        PackageKey.published?(key.raw_public_key)

      Signer.new(name: name, key: key.raw_public_key)
    rescue OpenSSL::PKey::PKeyError
      raise Error, "--signer #{path} is not a PEM public key"
    end

    # The Plan of packages (Package), each row enabled when enable names it, and a signer
    # row for each of signers. An image takes one package of a name and one signer of a
    # name, and enable names only packages it takes. local makes it a local test image's.
    def plan(packages, enable:, signers: [], local: false)
      refuse_twice(packages.map(&:name), 'two packages of the image are named')
      refuse_twice(signers.map(&:name), 'two signers of the image are named')
      unknown = enable - packages.map(&:name)
      raise Error, "--enable names #{unknown.join(', ')}, which no added package is" unless unknown.empty?

      sorted = packages.sort_by(&:name).freeze
      records = [*sorted.map { |package| package_record(package, enabled: enable.include?(package.name)) },
                 *signers.sort_by(&:name).map { |signer| signer_record(signer) }]
      raise Error, 'local is true or false' unless [true, false].include?(local)

      Plan.new(packages: sorted, rows: Manifest::Frontend.records_text(records).freeze, local: local)
    end

    # The image with no packages, which adds no row and is no local test image.
    def none = plan([], enable: [])

    def copied(source, into)
      raise Error, "#{source} is neither an app directory nor a package file" unless File.file?(source)

      target = File.join(into, File.basename(source))
      File.open(source, 'rb') do |input|
        File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) { |output| IO.copy_stream(input, output) }
      end
      target
    rescue SystemCallError => error
      raise Error, "cannot take the package #{source}: #{error.message}"
    end

    def refuse_twice(names, what)
      twice = names.tally.select { |_name, count| count > 1 }.keys
      raise Error, "#{what} #{twice.join(', ')}" unless twice.empty?
    end

    def package_record(package, enabled:)
      record('package', package.name, 'input' => "@artifact.#{package.artifact_name}", 'enable' => enabled ? 'YES' : 'NO')
    end

    def signer_record(signer) = record('signer', signer.name, 'key' => "hex:#{signer.key.unpack1('H*')}")

    # A manifest record of kind and name whose fields each hold one unquoted token.
    def record(kind, name, fields)
      Manifest::Record.new(kind: kind, name: name, parameters: [].freeze, line: nil,
                                     properties: fields.transform_values { |value| [ABI::Token.new(value: value, quoted: false)].freeze })
    end

    private_class_method :copied, :refuse_twice, :package_record, :signer_record, :record
  end
end
