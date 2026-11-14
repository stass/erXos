# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The ASN.1 specifications in an OTP application's asn1 directory and the modules
  # the ASN.1 compiler makes of them (lib/public_key/asn1/Makefile): each M.asn1 is
  # module M, and a set M.set.asn, which names one specification beside it per line
  # after its comment header, is module M, made of its members together, which are
  # no module of their own.
  module Asn1Specifications
    module_function

    # The modules the specifications in the directory asn1 make, sorted; none when
    # there is no such directory.
    def modules(asn1)
      sets = Dir.glob('*.set.asn', base: asn1)
      member_names = sets.flat_map { |set| members(File.join(asn1, set)) }.map { |path| File.basename(path) }
      singles = Dir.glob('*.asn1', base: asn1) - member_names
      (sets.map { |set| set.delete_suffix('.set.asn') } + singles.map { |name| name.delete_suffix('.asn1') }).sort
    end

    # The specifications module name is made from: its own, or its set and the set's
    # members; none when no specification makes it.
    def sources(asn1, name)
      specification = File.join(asn1, "#{name}.asn1")
      return [specification] if File.file?(specification)

      set = File.join(asn1, "#{name}.set.asn")
      File.file?(set) ? [set, *members(set)] : []
    end

    # The specifications a set names, one per line after its comment header: each a
    # plain file beside the set, which is a plain file itself, never one a link names.
    def members(set)
      raise Error, "#{set} is not a plain file" unless plain_file?(set)

      asn1 = File.dirname(set)
      File.readlines(set, chomp: true).reject { |line| line.empty? || line.start_with?('%') }.map do |name|
        member = name.match?(/\A[^\/\0.][^\/\0]*\z/) && File.join(asn1, name)
        unless member && plain_file?(member)
          raise Error, "#{set} names #{name.inspect}, which is not a specification beside it"
        end

        member
      end
    end

    def plain_file?(path) = File.file?(path) && !File.symlink?(path)
    private_class_method :plain_file?
  end
end
