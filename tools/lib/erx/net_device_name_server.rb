# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'qemu'

module Erx
  module NetDevice
    # The name server the harness plays on the guest's link once the ARP and ICMP exchange
    # is done, so the `host` command has a server whose answers the test fixes and the run
    # stays offline: slirp's own name server, 10.0.2.3, forwards to the host's resolver,
    # whose answers no test controls. It answers, from HOST_MAC and HOST_IP, ARP requests
    # for HOST_IP and DNS queries to HOST_IP port 53 from the records in RECORDS:
    # NOERROR with the matching records for a name RECORDS knows, NXDOMAIN for any other.
    #
    # Every frame comes from the guest, the code under test, so each is parsed with bounds
    # checks and one that is not a well-formed request of these two kinds is skipped. The
    # answers run on a thread of their own, from start until stop, while the boot's
    # checkpoints read the serial line.
    class NameServer
      DNS_PORT = 53
      PROTOCOL_UDP = 17
      TYPE_A = 1
      TYPE_PTR = 12
      TYPE_AAAA = 28
      CLASS_IN = 1
      TTL = 60
      RCODE_NXDOMAIN = 3
      POLL_SECONDS = 0.2
      # The name the records answer for and its addresses: the host command's checks.
      NAME = "www.#{QemuPlan::NIC_DOMAIN}"
      ADDRESS = [192, 0, 2, 10].freeze
      ADDRESS6 = [0x2001, 0xdb8, 0, 0, 0, 0, 0, 0x10].freeze
      POINTER = "#{ADDRESS.reverse.join('.')}.in-addr.arpa"

      def self.labels(name) = name.split('.').map { |label| [label.bytesize].pack('C') + label.b }.join + "\0".b

      RECORDS = {
        [NAME, TYPE_A] => ADDRESS.pack('C*'),
        [NAME, TYPE_AAAA] => ADDRESS6.pack('n*'),
        [POINTER, TYPE_PTR] => labels(NAME)
      }.freeze
      NAMES = RECORDS.keys.map(&:first).uniq.freeze

      def initialize(link)
        @link = link
        @stopped = false
        @thread = nil
      end

      # The thread's value is the error it met, or nil, so stopping it never raises and a
      # run's own failure is never replaced by the server's.
      def start
        @thread = Thread.new do
          @link.await(POLL_SECONDS) { |frame| answer(frame) } until @stopped
          nil
        rescue StandardError => e
          e
        end
        self
      end

      # Stops the answers and returns the error the thread met, or nil.
      def stop
        @stopped = true
        @thread&.value
      end

      private

      # Sends the answer to frame, if it is one this server answers, and returns nil so the
      # link's await goes on reading.
      def answer(frame)
        reply = arp_reply(frame) || dns_reply(frame)
        @link.send(reply) if reply
        nil
      end

      def arp_reply(frame)
        return nil unless frame.bytesize >= 42 && frame.unpack1('@12n') == ETHERTYPE_ARP

        htype, ptype, hlen, plen, op = frame.unpack('@14nnCCn')
        sender, sender_ip, _target, target_ip = frame.unpack('@22a6a4a6a4')
        return nil unless [htype, ptype, hlen, plen, op] == [1, ETHERTYPE_IP, 6, 4, 1] && target_ip == NetDevice.bytes(HOST_IP)

        NetDevice.ethernet(sender.bytes, ETHERTYPE_ARP,
                           [1, ETHERTYPE_IP, 6, 4, 2].pack('nnCCn') + NetDevice.bytes(HOST_MAC) + NetDevice.bytes(HOST_IP) +
                           sender + sender_ip)
      end

      def dns_reply(frame)
        datagram = udp_to_server(frame)
        return nil unless datagram

        response = dns_response(datagram.fetch(:payload))
        response && udp_frame(datagram, response)
      end

      # The source and payload of a UDP datagram to HOST_IP port 53, or nil.
      def udp_to_server(frame)
        return nil unless frame.bytesize >= 34 && frame.unpack1('@12n') == ETHERTYPE_IP

        version_ihl, total, protocol, source, destination = frame.unpack('@14C@16n@23C@26a4a4')
        header = (version_ihl & 0x0f) * 4
        return nil unless version_ihl >> 4 == 4 && header >= 20 && protocol == PROTOCOL_UDP && total >= header + 8 &&
                          frame.bytesize >= 14 + total && destination == NetDevice.bytes(HOST_IP)

        udp = frame.byteslice(14 + header, total - header)
        source_port, destination_port, length = udp.unpack('nnn')
        return nil unless destination_port == DNS_PORT && length >= 8 && length <= udp.bytesize

        { mac: frame.byteslice(6, 6), ip: source, port: source_port, payload: udp.byteslice(8, length - 8) }
      end

      # The response to a standard query of one question, or nil for anything else.
      def dns_response(query)
        return nil unless query.bytesize >= 12

        id, flags, questions = query.unpack('nnn')
        return nil unless questions == 1 && (flags & 0xf800).zero?

        name, finish = question_name(query, 12)
        return nil unless name && query.bytesize >= finish + 4

        type, klass = query.unpack("@#{finish}nn")
        return nil unless klass == CLASS_IN

        answers = RECORDS.key?([name, type]) ? [RECORDS.fetch([name, type])] : []
        rcode = NAMES.include?(name) ? 0 : RCODE_NXDOMAIN
        header = [id, 0x8400 | (flags & 0x0100) | rcode, 1, answers.size, 0, 0].pack('n6')
        header + query.byteslice(12, finish + 4 - 12) +
          answers.map { |data| [0xc00c, type, CLASS_IN, TTL, data.bytesize].pack('nnnNn') + data }.join
      end

      # The question's name, lowercased, and the offset after it; nil for a compressed or
      # malformed name.
      def question_name(query, offset)
        labels = []
        loop do
          return nil if offset >= query.bytesize

          length = query.getbyte(offset)
          return [labels.join('.').downcase, offset + 1] if length.zero?
          return nil if length > 63 || offset + 1 + length > query.bytesize

          labels << query.byteslice(offset + 1, length)
          offset += 1 + length
        end
      end

      def udp_frame(datagram, payload)
        length = 8 + payload.bytesize
        pseudo = NetDevice.bytes(HOST_IP) + datagram.fetch(:ip) + [0, PROTOCOL_UDP, length].pack('CCn')
        udp = [DNS_PORT, datagram.fetch(:port), length, 0].pack('nnnn') + payload
        udp = NetDevice.with_checksum(pseudo + udp, at: pseudo.bytesize + 6).byteslice(pseudo.bytesize..)
        # A sum of zero goes as all ones, since zero means no checksum (RFC 768).
        udp[6, 2] = "\xff\xff".b if udp.unpack1('@6n').zero?
        header = [0x45, 0, 20 + length, 0, 0, 64, PROTOCOL_UDP, 0].pack('CCnnnCCn') + NetDevice.bytes(HOST_IP) +
                 datagram.fetch(:ip)
        NetDevice.ethernet(datagram.fetch(:mac).bytes, ETHERTYPE_IP, NetDevice.with_checksum(header, at: 10) + udp)
      end
    end
  end
end
