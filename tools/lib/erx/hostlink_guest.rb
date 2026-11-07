# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'socket'
require_relative 'error'
require_relative 'etf'
require_relative 'hostlink_client'

module Erx
  # The host link's checks end to end, against a booted guest's system domain over its
  # second UART (docs/design-live.md, "The host link"; docs/plan.md, M4's exit criteria:
  # session replacement, at-most-once calls, credit and the 1,025th facet). The pure
  # session machine has its exhaustive host tests (test/erlang/erx_hostlink_session_tests.erl);
  # these show the same rules hold through erx_hostlink's effects, erx_pl011 and QEMU's
  # socket, with the Ruby client as the host. Each check raises Erx::Error naming what
  # the guest answered instead.
  module HostlinkGuest
    # The seconds the checks take on a loaded host, with a wide margin: about 1,100 calls.
    SECONDS = 300
    FACETS = 1_024

    OK = Etf::Atom.new(name: 'ok')
    ERROR = Etf::Atom.new(name: 'error')
    HOST_CAP = Etf::Atom.new(name: '$host_cap')
    OPEN_INSTALL = Etf::Tuple.new(elements: [Etf::Atom.new(name: 'open'), Etf::Atom.new(name: 'install')])

    module_function

    # Connects to the guest's host link at socket and runs every check; build is the boot
    # image's build identifier, which the hello reply must carry. Returns what was seen.
    def call(socket, build:)
      UNIXSocket.open(socket) do |io|
        client = HostlinkClient.new(io: io, expected_build: build)
        first = client.hello
        facet = expect_facet(client.call(OPEN_INSTALL), 1)
        missing = install_missing(client, facet)
        repeated = at_most_once(client)
        sent = full_table(client, opened: 3, repeated: repeated)
        replaced = replacement(client, first, facet)
        { session: first.id.unpack1('H*'), replaced: replaced.unpack1('H*'), missing: missing, bytes_sent: sent }
      end
    end

    # The install facet serves the code service's requests: a hash the store lacks is
    # reported missing (docs/design-live.md, "Sending only what is missing").
    def install_missing(client, facet)
      hash = Digest::SHA256.digest('erx hostlink guest check')
      reply = client.call(Etf::Tuple.new(elements: [Etf::Atom.new(name: 'missing'), [hash]]), target: facet)
      check(reply == Etf::Tuple.new(elements: [OK, [hash]]), 'missing', reply)
      1
    end

    # A call sent twice under one identifier executes once: the repeat gets the kept reply,
    # the same facet number, and the next open gets the next number. Returns the identifier.
    def at_most_once(client)
      id = client.next_id
      client.send_call(OPEN_INSTALL, id: id)
      first = client.await(id)
      client.send_call(OPEN_INSTALL, id: id)
      repeat = client.await(id)
      check(first == repeat, 'a repeated call', repeat)
      expect_facet(first, 2)
      expect_facet(client.call(OPEN_INSTALL), 3)
      id
    end

    # Opens facets until the table holds FACETS; one more is refused with system_limit, and
    # the identifier repeated of the at-most-once check, now below the window, is expired. The
    # bytes sent pass the initial credit many times over, so every grant along the way
    # had to arrive for the calls to go out.
    def full_table(client, opened:, repeated:)
      (opened + 1..FACETS).each { |number| expect_facet(client.call(OPEN_INSTALL), number) }
      limit = client.call(OPEN_INSTALL)
      check(limit == error(:system_limit), 'the 1,025th facet', limit)
      client.send_call(OPEN_INSTALL, id: repeated)
      expired = client.await(repeated)
      check(expired == error(:expired), 'a call below the window', expired)
      sent = client.bytes_sent
      check(sent > 2 * HostlinkFrame::CREDIT_INITIAL, 'the bytes sent', sent)
      sent
    end

    # A hello with a new nonce replaces the session: a new identifier, and the old
    # session's facet numbers name nothing in it.
    def replacement(client, first, facet)
      second = client.hello
      check(second.id != first.id, 'the replacing session identifier', second.id.unpack1('H*'))
      gone = client.call(OPEN_INSTALL, target: facet)
      check(gone == error(:noproc), 'a facet of the replaced session', gone)
      expect_facet(client.call(OPEN_INSTALL), 1)
      second.id
    end

    def expect_facet(reply, number)
      check(reply == Etf::Tuple.new(elements: [OK, Etf::Tuple.new(elements: [HOST_CAP, number])]), "facet #{number}", reply)
      number
    end

    def error(reason) = Etf::Tuple.new(elements: [ERROR, Etf::Atom.new(name: reason.to_s)])

    def check(holds, what, seen)
      raise Error, "host link: #{what}: the guest answered #{HostlinkClient.show(seen)}" unless holds
    end
  end
end
