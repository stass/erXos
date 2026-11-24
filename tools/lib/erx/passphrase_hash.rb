# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'io/console'
require 'openssl'
require 'securerandom'
require_relative 'error'

module Erx
  # `tools/erx passphrase-hash`: writes root's passphrase line for the record
  # volume's passphrase_hash (docs/design-ssh.md, "Root's passphrase on the
  # medium"), one crypt(3) SHA-256 string as FreeBSD 14.3.0's
  # lib/libcrypt/crypt-sha256.c writes it, under a fresh 16-character salt and
  # crypt's default 5000 rounds. The passphrase is read twice from the terminal
  # without echo, or once as a line of standard input when that is not a
  # terminal; it is never printed or logged.
  module PassphraseHash
    ALPHABET = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    SALT_CHARS = 16
    DEFAULT_ROUNDS = 5000
    PASSPHRASE_MAX = 256
    # crypt-sha256.c's order of the hash's bytes: ten groups of three, each spelled
    # in four characters of the 24-bit word from its low six bits, then 31 and 30.
    GROUPS = [[0, 10, 20], [21, 1, 11], [12, 22, 2], [3, 13, 23], [24, 4, 14],
              [15, 25, 5], [6, 16, 26], [27, 7, 17], [18, 28, 8], [9, 19, 29]].freeze

    # A passphrase the line cannot be written for.
    class Refused < Erx::Error; end

    module_function

    def command(arguments, input: $stdin, output: $stdout)
      raise Refused, 'usage: erx passphrase-hash > passphrase_hash' unless arguments.empty?

      output.puts(line(read_passphrase(input)))
    end

    # The crypt(3) SHA-256 line of passphrase under salt, as crypt_sha256() writes it.
    def line(passphrase, salt: random_salt, rounds: DEFAULT_ROUNDS)
      unless passphrase.bytesize.between?(1, PASSPHRASE_MAX)
        raise Refused, "a passphrase is 1 to #{PASSPHRASE_MAX} bytes"
      end

      field = rounds == DEFAULT_ROUNDS ? '' : "rounds=#{rounds}$"
      "$5$#{field}#{salt}$#{spelled(derive(passphrase.b, salt.b, rounds))}"
    end

    # crypt_sha256()'s 32 bytes: each step hashes what crypt-sha256.c feeds one context.
    def derive(key, salt, rounds)
      alternate = sha(key + salt + key)
      bits = key.bytesize.digits(2).map { |bit| bit == 1 ? alternate : key }
      sum = sha(key + salt + cycled(alternate, key.bytesize) + bits.join)
      p_bytes = cycled(sha(key * key.bytesize), key.bytesize)
      s_bytes = cycled(sha(salt * (16 + sum.getbyte(0))), salt.bytesize)
      rounds.times.reduce(sum) do |last, round|
        sha([round.odd? ? p_bytes : last, round % 3 == 0 ? '' : s_bytes,
             round % 7 == 0 ? '' : p_bytes, round.odd? ? last : p_bytes].join)
      end
    end

    def spelled(hash)
      bytes = hash.bytes
      words = GROUPS.map { |b2, b1, b0| [(bytes[b2] << 16) | (bytes[b1] << 8) | bytes[b0], 4] } +
              [[(bytes[31] << 8) | bytes[30], 3]]
      words.map { |word, chars| (0...chars).map { |i| ALPHABET[(word >> (6 * i)) & 63] }.join }.join
    end

    def sha(bytes) = OpenSSL::Digest::SHA256.digest(bytes)

    def cycled(sum, length) = (sum * ((length / sum.bytesize) + 1)).byteslice(0, length)

    def random_salt = Array.new(SALT_CHARS) { ALPHABET[SecureRandom.random_number(64)] }.join

    def read_passphrase(input)
      return input.gets&.chomp.to_s unless input.tty?

      first = input.getpass('passphrase: ')
      raise Refused, 'the passphrases differ' unless input.getpass('again: ') == first

      first
    end
  end
end
