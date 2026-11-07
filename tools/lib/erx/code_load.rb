# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'etf'
require_relative 'hostlink_client'

module Erx
  # Loading compiled modules into the system domain from the host, over a host link
  # session's install facet (docs/design-live.md, "Code from the host" and "The code
  # store"): `tools/erx load` and `tools/erx watch` both end here.
  #
  # A load is the missing-blob exchange: the host names every module's hash and asks which
  # blobs the code store lacks, sends only those, each in pieces of at most 64 KiB, and then
  # loads the manifest, `[{Name, Hash}]`, as one batch. The guest checks every blob against
  # its hash when its last piece arrives and loads by hash, so the host's hashes are a
  # request, not a trust: a blob whose bytes differ from its hash is refused there.
  #
  # Every reply comes from the guest and is untrusted; a refusal reaches the caller as a
  # Refused error whose text shows the reply through HostlinkClient.show, the line escape.
  module CodeLoad
    # The guest refused a step of a load, or answered outside the code service's replies.
    class Refused < Error; end

    # The code store's piece size and module name bound (erlang/apps/erx_code/src/erx_code_store.erl).
    PIECE_MAX = 65_536
    NAME_MAX = 255
    MANIFEST_MAX = 1_024

    OK = Etf::Atom.new(name: 'ok')
    STORED = Etf::Atom.new(name: 'stored')
    NEXT = Etf::Atom.new(name: 'next')
    HOST_CAP = Etf::Atom.new(name: '$host_cap')
    OPEN_INSTALL = Etf::Tuple.new(elements: [Etf::Atom.new(name: 'open'), Etf::Atom.new(name: 'install')])

    # One module to load: its name as the guest makes it an atom, the SHA-256 of its bytes,
    # and the bytes.
    Blob = Data.define(:name, :sha256, :bytes) do
      # The blob of a compiled module's file, named by the file's base name as erlc names it.
      def self.from_file(path)
        name = File.basename(path, '.beam')
        raise Error, "#{path}: a module's file is named MODULE.beam" unless path.end_with?('.beam') && !name.empty?

        of(name: name, bytes: File.binread(path))
      end

      # The blob of bytes named name; a name the code store would refuse is refused here.
      def self.of(name:, bytes:)
        raise Error, "module name #{name.inspect} is not 1 to #{NAME_MAX} bytes of a module name" unless
          CodeLoad.module_name?(name)
        raise Error, "module #{name} is empty" if bytes.empty?

        new(name: name.b.freeze, sha256: Digest::SHA256.digest(bytes).freeze, bytes: bytes.b.freeze)
      end

      def hex = sha256.unpack1('H*')
    end

    # What one load did: the modules it sent, which the store lacked, and the modules it loaded.
    Result = Data.define(:sent, :loaded)

    module_function

    # A module name the host sends: letters, digits, `_` and `@`, starting with a lowercase
    # letter, so it needs no quotes and holds no control byte. The store takes more (any
    # name of 1 to 255 bytes); a module whose name needs quotes is refused here.
    def module_name?(name) = name.is_a?(String) && name.bytesize.between?(1, NAME_MAX) && name.match?(/\A[a-z][A-Za-z0-9_@]*\z/)

    # The pieces of blob, as [offset, bytes], every one PIECE_MAX bytes but the last.
    def pieces(blob) = (0...blob.bytes.bytesize).step(PIECE_MAX).map { |offset| [offset, blob.bytes.byteslice(offset, PIECE_MAX)] }

    # The request terms of the exchange, as erx_code_store:read_request/1 reads them.
    def missing_request(blobs) = Etf::Tuple.new(elements: [Etf::Atom.new(name: 'missing'), blobs.map(&:sha256)])

    def put_request(blob, offset, piece) =
      Etf::Tuple.new(elements: [Etf::Atom.new(name: 'put'), blob.sha256, blob.bytes.bytesize, offset, piece])

    def load_request(blobs) =
      Etf::Tuple.new(elements: [Etf::Atom.new(name: 'load'), blobs.map { |blob| Etf::Tuple.new(elements: [blob.name, blob.sha256]) }])

    # Opens the install facet on client's session and returns its number.
    def open_install(client)
      reply = client.call(OPEN_INSTALL)
      case reply
      in Etf::Tuple[[OK, Etf::Tuple[[HOST_CAP, Integer => facet]]]] if facet.positive?
        facet
      else
        raise Refused, "opening the install facet: the guest answered #{HostlinkClient.show(reply)}"
      end
    end

    # Loads blobs into the system domain through the install facet facet, as one batch,
    # sending only the blobs the store lacks. Returns a Result; raises Refused naming the
    # step and the guest's answer when the guest refuses any step.
    def install(client, facet:, blobs:)
      check_batch(blobs)
      lacking = missing(client, facet: facet, blobs: blobs)
      sent = blobs.select { |blob| lacking.include?(blob.sha256) }
      sent.each { |blob| put(client, facet: facet, blob: blob) }
      reply = client.call(load_request(blobs), target: facet)
      raise Refused, "loading #{names(blobs)}: the guest answered #{HostlinkClient.show(reply)}" unless reply == OK

      Result.new(sent: sent.map(&:name), loaded: blobs.map(&:name))
    end

    # The hashes of blobs the store lacks, as the guest answered; a hash the host did not
    # ask about is a refusal.
    def missing(client, facet:, blobs:)
      reply = client.call(missing_request(blobs), target: facet)
      asked = blobs.map(&:sha256)
      case reply
      in Etf::Tuple[[OK, Array => hashes]] if hashes.all? { |hash| asked.include?(hash) }
        hashes
      else
        raise Refused, "asking which of #{names(blobs)} the store lacks: the guest answered #{HostlinkClient.show(reply)}"
      end
    end

    # Sends blob piece by piece; the store must ask for each next piece where it ends and
    # answer the last with stored. A store that answers stored early holds the blob already,
    # stored meanwhile by another session, and nothing more is sent.
    def put(client, facet:, blob:)
      pieces(blob).each do |offset, piece|
        ends = offset + piece.bytesize
        reply = client.call(put_request(blob, offset, piece), target: facet)
        return if reply == Etf::Tuple.new(elements: [OK, STORED])
        next if ends < blob.bytes.bytesize && reply == Etf::Tuple.new(elements: [OK, Etf::Tuple.new(elements: [NEXT, ends])])

        raise Refused, "sending #{blob.name} at #{offset}: the guest answered #{HostlinkClient.show(reply)}"
      end
    end

    def check_batch(blobs)
      raise Error, "a load names 1 to #{MANIFEST_MAX} modules" unless blobs.size.between?(1, MANIFEST_MAX)

      duplicate = blobs.map(&:name).tally.find { |_name, count| count > 1 }
      raise Error, "module #{duplicate.first} is named twice in one load" if duplicate
    end

    def names(blobs) = blobs.map(&:name).join(' ')
  end
end
