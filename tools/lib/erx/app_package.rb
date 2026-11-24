# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'openssl'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'gatt_decl'
require_relative 'origin'

module Erx
  # An app's package, NAME.app (docs/design-packaging.md, "The package"), as values: the
  # declaration parsed from app.txt ("The declaration"), the dm-verity hash tree over the
  # package's EROFS image, and the header, encoded through the ABI codec from
  # abi/formats/package.txt and sealed with the signer's key and signature. Everything
  # here is pure but reading a signing key; Erx::AppPack reads an app's directory and
  # writes the file.
  module AppPackage
    # How an app starts: its OTP applications, or its program under the image's bin/ and
    # the program's arguments. A declaration has exactly one.
    Applications = Data.define(:names)
    Program = Data.define(:path, :args)
    # The declaration's fields; start is an Applications or a Program, gatt the GATT
    # services the app handles, [] when app.txt names none, and license '' when it
    # names none.
    Declaration = Data.define(:name, :needs, :gatt, :start, :license, :memory, :version)
    # A hash tree's bytes, its levels top first, the salt every hash was salted with, and
    # its root hash.
    Tree = Data.define(:bytes, :salt, :root_hash)

    # The most bytes of app.txt.
    DECLARATION_MAX = 16 * 1024
    # An app's name and an OTP application's: the app's name is also its principal's and
    # its package file's.
    APPLICATION = /\A[a-z][a-z0-9_]{0,62}\z/
    # A service's identifier, as the manifest spells it.
    NEED = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
    DECIMAL = /\A[1-9][0-9]{0,19}\z/
    # A GATT service's name, as abi/gatt spells it; admission holds each to the names
    # the board's apps row offers.
    GATT_NAME = GattDecl::NAME
    # The service only gatt takes (docs/design-packaging.md, "The declaration").
    BLE = 'ble'
    FIELDS = %w[needs gatt applications program memory version license].freeze
    U32_MAX = 0xffff_ffff
    U64_MAX = 0xffff_ffff_ffff_ffff

    # An Ed25519 signing key read from a PEM file the developer names. Neither the key's
    # bytes nor the file's text appear in an error or anywhere but the signature. A file
    # holding only a public key fails the trial signature.
    class Signer
      # The most bytes of a key file; a PEM Ed25519 private key takes about 120.
      KEY_MAX = 16 * 1024

      def self.read(path)
        key = OpenSSL::PKey.read(BoundedFile.read(path, maximum: KEY_MAX))
        raise Error, 'not an Ed25519 key' unless key.oid == 'ED25519'

        key.sign(nil, ''.b)
        new(key)
      rescue OpenSSL::PKey::PKeyError, Error => error
        raise Error, "cannot read the signing key #{path}: #{error.is_a?(Error) ? error.message : 'not a PEM private key'}"
      end

      def initialize(key)
        @key = key
        freeze
      end

      def public_key = @key.raw_public_key
      def sign(bytes) = @key.sign(nil, bytes)
    end

    module_function

    def codec
      @codec ||= ABI::Codec.new(ABI::Generator.plan(root: File.expand_path('../../..', __dir__)).schema)
    end

    def block = codec.constant('erofs_block_size')

    # The declaration app.txt's text holds; path names it in errors.
    def parse_declaration(text, path:)
      raise Error, "#{path}: a declaration is at most #{DECLARATION_MAX} bytes" if text.bytesize > DECLARATION_MAX

      rows = ABI::Syntax.parse(text, path: path)
      raise Error, "#{path}: a declaration holds exactly one app row" unless rows.size == 1 && rows.first.kind == 'app'

      row = rows.first
      row.fail!('an app row names the app') unless row.line.tokens.size == 2
      fields = row.members.each_with_object({}) do |line, seen|
        keyword = line.words.first
        line.fail!("unknown field #{keyword}") unless line.indent == 2 && FIELDS.include?(keyword)
        line.fail!("#{keyword} given twice") if seen.key?(keyword)
        seen[keyword] = line
      end
      Declaration.new(name: identifier(row.line, row.line.tokens.last, APPLICATION, 'app name'),
                      needs: needs(fields['needs']),
                      gatt: fields['gatt'] ? names(fields['gatt'], GATT_NAME, 'GATT service name', limit: 'service_ble_services_max') : [],
                      start: start(row, fields), license: license(fields['license']),
                      memory: number(fields['memory'], minimum: codec.constant('app_memory_min'), maximum: U64_MAX,
                                                       default: codec.constant('app_memory_default')),
                      version: number(fields['version'], minimum: 1, maximum: U32_MAX, default: 1))
    end

    # The dm-verity tree, format version 1 with SHA-256, over image, whose length is a
    # multiple of the block: the lowest level holds each image block's hash, each level
    # above the hash of each block of the level below, every hash salted by prefixing salt
    # and every level zero-filled to whole blocks, until a level fits in one block, whose
    # hash is the root hash; an image of one block has no level and its block's hash is the
    # root hash. The levels lie top first. erx_verity_tree gives the same levels' lengths.
    def verity_tree(image, salt:)
      raise Error, 'an image is a whole number of blocks' unless image.bytesize.positive? && (image.bytesize % block).zero?

      levels = levels(image.b, salt)
      Tree.new(bytes: levels.reverse.join.freeze, salt: salt.b.freeze,
               root_hash: Digest::SHA256.digest(salt + (levels.last || image.b)))
    end

    # The dm-verity tree over image under the salt every EROFS image erXos writes takes,
    # the image's own SHA-256 (docs/design-packaging.md, "Building and packing"): a
    # package's image and the booted slot's system image alike, so the same image always
    # has the same tree.
    def image_tree(image) = verity_tree(image, salt: Digest::SHA256.digest(image))

    # The levels over data, lowest first.
    def levels(data, salt)
      return [] if data.bytesize <= block

      hashes = (0...(data.bytesize / block)).map { |index| Digest::SHA256.digest(salt + data.byteslice(index * block, block)) }.join
      level = hashes.ljust(((hashes.bytesize + block - 1) / block) * block, "\0")
      [level, *levels(level, salt)]
    end

    # The architecture the codec was planned for, an architecture name of abi/arch/, which
    # is also the one its ABI version covers.
    def architecture = codec.schema.architecture.fetch(:name)

    # The header of a package of declaration for the codec's architecture, sealed by
    # signer: anything with public_key, its 32-byte Ed25519 key, and sign(bytes), the
    # signature over bytes. The string table holds arch, name, license, a native app's
    # program and args (each NUL-terminated), the needs, the gatt and the applications, in that
    # order. The seal ends the header and the signature ends the seal (the reader's order
    # in abi/formats/package.txt), so the signature covers every byte of the header before
    # it, the key included. A block, when given, receives the fixed part's values once the
    # layout is computed and returns those encoded.
    def header(declaration, image_blocks:, tree_blocks:, salt:, root_hash:, signer:, &edits)
      kind, start_texts, applications = case declaration.start
                                        in Applications(names:) then ['erlang', {}, names]
                                        in Program(path:, args:)
                                          ['native', { 'program' => path, 'args' => args.map { |arg| "#{arg}\0" }.join }, []]
                                        end
      texts = { 'arch' => architecture, 'name' => declaration.name, 'license' => declaration.license, **start_texts }
      strings = [*texts.values, *declaration.needs, *declaration.gatt, *applications]
      references = string_references(strings)
      none = { 'offset' => 0, 'length' => 0 }
      root = { 'version' => codec.constant('pkg_version'), 'abi_version' => codec.abi_version,
               'kind' => codec.member('pkg_kind', kind), 'app_version' => declaration.version,
               'memory' => declaration.memory, 'image_blocks' => image_blocks, 'tree_blocks' => tree_blocks,
               'salt' => salt, 'root_hash' => root_hash, 'program' => none, 'args' => none,
               **texts.keys.zip(references.first(texts.size)).to_h }
      seal = { 'key' => signer.public_key, 'signature' => "\0".b * codec.schema.types.fetch('pkg_signature').size }
      listed = references.drop(texts.size)
      tables = { 'needs' => listed.first(declaration.needs.size),
                 'gatt' => listed.drop(declaration.needs.size).first(declaration.gatt.size),
                 'applications' => listed.drop(declaration.needs.size + declaration.gatt.size),
                 'strings' => strings.join.b, 'seal' => [seal] }
      unsigned = codec.encode_reader('pkg_reader', root, tables: tables, &edits)
      signed = unsigned.byteslice(0, unsigned.bytesize - seal.fetch('signature').bytesize)
      (signed + signer.sign(signed)).freeze
    end

    # The reference of each of texts laid end to end in a string table.
    def string_references(texts)
      offsets = texts.each_with_object([0]) { |text, ends| ends << (ends.last + text.bytesize) }
      texts.zip(offsets).map { |text, offset| { 'offset' => offset, 'length' => text.bytesize } }
    end

    def start(row, fields)
      case fields.values_at('applications', 'program')
      in [line, nil] if line then Applications.new(names: names(line, APPLICATION, 'application', limit: 'pkg_applications_max'))
      in [nil, line] if line then program(line)
      else row.fail!('a declaration names exactly one of applications and program')
      end
    end

    def program(line)
      path, *args = line.tokens.drop(1).map(&:value)
      line.fail!('program names a path of plain names under bin/') unless path&.start_with?('bin/') && codec.string_class?('relative_path', path)
      line.fail!("the program path is longer than #{codec.constant('pkg_program_max')} bytes") if path.bytesize > codec.constant('pkg_program_max')
      line.fail!("program takes at most #{codec.constant('pkg_args_max')} arguments") if args.size > codec.constant('pkg_args_max')
      line.fail!('a program argument holds no NUL') if args.any? { |arg| arg.include?("\0") }
      line.fail!('the program arguments are too long') if args.sum { |arg| arg.bytesize + 1 } > codec.constant('pkg_args_bytes_max')
      Program.new(path: path.freeze, args: args.map(&:freeze).freeze)
    end

    # The services of the apps row the app takes: never ble, which only gatt takes, so no
    # app holds a ble grant that names nothing.
    def needs(line)
      return [] unless line

      line.fail!("needs never names #{BLE}: gatt names the services an app handles") if line.words.drop(1).include?(BLE)
      names(line, NEED, 'need', limit: 'pkg_needs_max')
    end

    def names(line, form, what, limit:)
      values = line.tokens.drop(1).map { |token| identifier(line, token, form, what) }
      line.fail!("#{line.words.first} names 1 to #{codec.constant(limit)} values") unless values.size.between?(1, codec.constant(limit))
      line.fail!("#{line.words.first} names a value twice") unless values.uniq.size == values.size
      values.freeze
    end

    def identifier(line, token, form, what)
      line.fail!("not an #{what}: #{token.value.inspect}") if token.quoted || !form.match?(token.value)
      token.value.freeze
    end

    def license(line)
      return '' unless line

      line.fail!('license is one quoted SPDX expression') unless line.tokens.size == 2 && line.tokens.last.quoted
      expression = line.tokens.last.value
      line.fail!("license is at most #{codec.constant('pkg_license_max')} bytes") if expression.bytesize > codec.constant('pkg_license_max')
      line.fail!('license holds printable ASCII alone') unless expression.match?(/\A[\x20-\x7e]*\z/)
      begin
        Attribution.validate_expression(expression)
      rescue Error => error
        line.fail!("license is not an SPDX expression: #{error.message}")
      end
      expression.freeze
    end

    def number(line, minimum:, maximum:, default:)
      return default unless line

      words = line.words.drop(1)
      unless words.size == 1 && !line.tokens.last.quoted && DECIMAL.match?(words.first) && words.first.to_i.between?(minimum, maximum)
        line.fail!("#{line.words.first} is a decimal number from #{minimum} to #{maximum}")
      end
      words.first.to_i
    end

    private_class_method :levels, :string_references, :start, :program, :needs, :names, :identifier, :license, :number
  end
end
