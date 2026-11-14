# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bounded_file'
require_relative 'error'

module Erx
  # The two build checks of docs/design-crypto.md ("Verification") on a linked runtime
  # image, read from its link map and its symbols:
  # * the system image holds no OpenSSL (K1): its link takes no member of libcrypto.a,
  #   crypto.a or asn1rt_nif.a, and its static NIF table names neither NIF;
  # * the seed path of the interpreter and BeamAsm images (K2): the image links musl's
  #   getrandom.o and libcrypto's rand_unix member, whose syscall_random calls it, defines
  #   getrandom, holds no weak undefined getentropy, and its NIF table names crypto.
  # NativeRoot runs them on every link of the three images; the decisions are pure
  # functions of the map's text and the symbol listing, which the host tests seed.
  module CryptoImage
    # The archives only the interpreter and BeamAsm images link.
    ARCHIVES = %w[libcrypto.a crypto.a asn1rt_nif.a].freeze
    # The init functions make_driver_tab's table names for the two NIFs.
    NIF_INITS = %w[crypto_nif_init asn1rt_nif_nif_init].freeze
    # A name only OpenSSL defines, whatever archive or object carried it in: its CPU
    # feature setup and word, and its internal and public namespaces.
    OPENSSL_NAME = /\A(?:OPENSSL_cpuid_setup|OPENSSL_armcap_P|ossl_|EVP_|OSSL_)/
    # ERTS's entry, which every runtime image defines; a listing without it is of a
    # stripped or wrong program and would pass as clean.
    WITNESS = 'erl_start'
    # An input of an LLD link map, archive(member), from one of ARCHIVES. The name starts
    # after a path separator or blank, so crypto.a never matches inside libcrypto.a.
    ARCHIVE_INPUT = %r{(?:\A|[/\s])(#{ARCHIVES.map { |name| Regexp.escape(name) }.join('|')})\(}
    GETRANDOM_INPUT = /libc\.a\(getrandom\.o\)/
    RAND_UNIX_INPUT = /libcrypto\.a\([^)]*rand_unix\.o\)/
    # One line of llvm-nm's default listing: an address for a defined symbol, the type
    # letter and the name.
    NM_LINE = /\A\h*\s+(?<type>[A-Za-z?-])\s+(?<name>\S+)\z/
    # Bounds on what is read: a link map of a runtime image is about 1 MiB, llvm-nm's
    # listing of it less.
    MAP_BYTES = 256 * 1024 * 1024
    NM_BYTES = 64 * 1024 * 1024
    NM_DEADLINE = 120

    module_function

    # The listing's symbols as { name => type letter }.
    def symbols(listing)
      listing.each_line(chomp: true).each_with_object({}) do |line, found|
        match = NM_LINE.match(line)
        found[match[:name]] = match[:type] if match
      end
    end

    # The ways the system image breaks K1, one sentence each; empty when it keeps it.
    def system_problems(map_text:, symbols:)
      archives = map_text.scan(ARCHIVE_INPUT).flatten.uniq.sort
      openssl = symbols.keys.grep(OPENSSL_NAME).sort
      [("its symbols list no #{WITNESS}" unless symbols.key?(WITNESS)),
       *archives.map { |name| "its link takes members of #{name}" },
       *NIF_INITS.select { |name| symbols.key?(name) }.map { |name| "its static NIF table names #{name}" },
       ("it defines OpenSSL's #{openssl.first(3).join(' ')}" unless openssl.empty?)].compact
    end

    # The ways an interpreter or BeamAsm image breaks the seed path, one sentence each.
    def seed_problems(map_text:, symbols:)
      [("its link takes no getrandom.o from musl's libc.a" unless GETRANDOM_INPUT.match?(map_text)),
       ("its link takes no rand_unix member of libcrypto.a" unless RAND_UNIX_INPUT.match?(map_text)),
       ('it does not define getrandom' unless %w[T t].include?(symbols['getrandom'])),
       ("it holds getentropy weak and undefined (#{symbols['getentropy']})" if %w[w v].include?(symbols['getentropy'])),
       *NIF_INITS.reject { |name| symbols.key?(name) }.map { |name| "its static NIF table names no #{name}" }].compact
    end

    # Raises unless program, the system image linked with map, keeps K1.
    def check_system(program:, map:, nm:, runner:)
      problems = system_problems(map_text: BoundedFile.read(map, maximum: MAP_BYTES),
                                 symbols: listing(program: program, nm: nm, runner: runner))
      raise Error, "the system image #{program} holds OpenSSL: #{problems.join('; ')}" unless problems.empty?
    end

    # Raises unless program, an interpreter or BeamAsm image linked with map, keeps the
    # seed path.
    def check_seed(program:, map:, nm:, runner:)
      problems = seed_problems(map_text: BoundedFile.read(map, maximum: MAP_BYTES),
                               symbols: listing(program: program, nm: nm, runner: runner))
      raise Error, "the runtime image #{program} breaks OpenSSL's seed path: #{problems.join('; ')}" unless problems.empty?
    end

    def listing(program:, nm:, runner:)
      record = runner.run([nm, program], name: 'crypto-image-nm', deadline: NM_DEADLINE, output_limit: NM_BYTES)
      symbols(BoundedFile.read(record.fetch('log'), maximum: NM_BYTES))
    end
    private_class_method :listing
  end
end
