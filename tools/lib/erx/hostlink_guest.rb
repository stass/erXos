# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'socket'
require_relative 'error'
require_relative 'etf'
require_relative 'hostlink_client'
require_relative 'abi_emit_web'
require_relative 'web_server'

module Erx
  # The host link's checks end to end, against a booted guest's system domain over its
  # second UART (docs/design-live.md, "The host link"; docs/plan.md, M4's exit criteria:
  # session replacement, at-most-once calls, credit and the 1,025th facet). The pure
  # session machine has its exhaustive host tests (test/erlang/erx_hostlink_session_tests.erl);
  # these show the same rules hold through erx_hostlink's effects, erx_pl011 and QEMU's
  # socket, with the Ruby client as the host. Last, the web facet carries one browser
  # connection to the web domain's connection core and back, through the host tool's own
  # relay (docs/design-web.md, "The host tool's front end"). Each check raises Erx::Error
  # naming what the guest answered instead.
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
        web = web_connection(client)
        { session: first.id.unpack1('H*'), replaced: replaced.unpack1('H*'), missing: missing, bytes_sent: sent,
          web: web }
      end
    end

    # Connects to the host link at socket of a guest whose console has logged root in,
    # and runs machine_record: build as for call/2, web_hash the web protocol's hash in
    # hexadecimal (web_hash/1). Returns the update's first bytes in hexadecimal.
    def machine(socket, build:, web_hash:)
      UNIXSocket.open(socket) do |io|
        machine_record(HostlinkClient.new(io: io, expected_build: build), web_hash)
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

    # The seconds the web domain has to answer a connection's message.
    WEB_SECONDS = 30

    # A connection the web facet carries reaches the web domain's connection core, and the
    # core's answer comes back: a message its codec refuses is answered with one message,
    # `bye protocol`, and the connection's end. Opening the facet starts a session of its
    # own. Returns the answer's bytes in hexadecimal.
    def web_connection(client)
      relay = Web::Relay.new(link: client)
      relay.open
      check(relay.connect(1), 'a web connection', relay)
      check(relay.data(1, "\xff".b), 'a message on the web connection', relay)
      seen = []
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WEB_SECONDS
      seen.concat(relay.messages(1)) until seen.any?(Web::Relay::Ended) ||
                                           Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      answered = seen in [Web::Relay::Delivered[1, String], Web::Relay::Ended[1]]
      raise Error, "host link: the web core's answer: the guest sent #{seen.map { |message| message.class.name }}" unless answered

      seen.first.bytes.unpack1('H*')
    end

    # The web protocol's hash for the tree at root, as the generated codecs carry it: over
    # the protocol's sources as the tree holds them (Erx::ABI::WebEmitter).
    def web_hash(root)
      inputs = ABI::WebEmitter::HASHED.to_h { |path| [path, File.binread(File.join(root, path))] }
      ABI::WebEmitter.protocol_hash(ABI::WebEmitter.hashed_sources(root: root, inputs: inputs))
    end

    # The web protocol's messages this check sends and expects, little-endian as
    # abi/protocols/web.txt lays them out: a browser's hello (tag 1, the 32-byte hash
    # as bytes, u32 length first) and its open of view 1 on the machine's path (tag 2,
    # view, target path, tag 1, of no segments); the tags of the welcome and of a view's
    # end; and the start of the update that answers the open with a record: tag 2, view
    # 1, body record (tag 1), the record's path of no segments and its kind, the atom
    # name `machine`.
    WELCOME = 1
    ENDED = 3
    OPEN_MACHINE = [2, 1, 1, 0].pack('CVCV').freeze
    MACHINE_UPDATE = ([2, 1, 1, 0, 7].pack('CVCVV') + 'machine').b.freeze

    def hello(hash) = [1, 32].pack('CV') + [hash].pack('H64')

    # A browser's open of the machine's path, on a connection through the web facet, is
    # answered with an update carrying the machine's record, which the web domain's line
    # to root's session read from the inspector (docs/design-web.md, "Views on the
    # line"). The facet reaches root's line as it opens; the console starts root's next
    # session when one ends, and a facet opened while none is logged in answers every
    # open `ended unsupported`, so the check opens the facet again until WEB_SECONDS
    # pass. Returns the update's first bytes in hexadecimal.
    def machine_record(client, hash)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WEB_SECONDS
      loop do
        update = machine_update(Web::Relay.new(link: client), hash)
        if update.getbyte(0) == ENDED
          raise Error, "host link: the machine's record: every open ended: #{update.unpack1('H*')}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 1
          next
        end
        check(update.start_with?(MACHINE_UPDATE), "the machine's record", update.unpack1('H*'))
        return update.byteslice(0, MACHINE_UPDATE.bytesize).unpack1('H*')
      end
    end

    # The machine's answer to an open of the machine's path on a fresh facet: an update
    # or the view's end.
    def machine_update(relay, hash)
      relay.open
      check(relay.connect(2), 'a web connection', relay)
      check(relay.data(2, hello(hash)), 'the hello', relay)
      welcome = delivered(relay, 2, 'the welcome')
      check(welcome.getbyte(0) == WELCOME, 'the welcome', welcome.unpack1('H*'))
      check(relay.data(2, OPEN_MACHINE), 'the open of the machine', relay)
      answer = delivered(relay, 2, "the machine's record")
      relay.close(2)
      answer
    end

    # The next message the machine delivered on connection number, within WEB_SECONDS.
    def delivered(relay, number, what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WEB_SECONDS
      loop do
        relay.messages(1).each do |message|
          case message
          in Web::Relay::Delivered[^number, String => bytes] then return bytes
          in Web::Relay::Ended[^number] then raise Error, "host link: #{what}: the web connection ended"
          else nil
          end
        end
        raise Error, "host link: #{what}: nothing came in #{WEB_SECONDS} seconds" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      end
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
