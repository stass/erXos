# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'socket'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The network stack end to end on QEMU virt: the development image boots with a
  # virtio-net device on QEMU's user networking (QemuPlan::Nic), the system domain's
  # erx_net drives it through erx_virtio_net and takes a DHCP lease from slirp, and the
  # harness, one more host on the guest's link through the hub's `dgram` port, asks it
  # for its address with ARP and pings it. The guest must answer both:
  #
  # * ARP: a request for GUEST_IP from HOST_MAC and HOST_IP, sent every ARP_RETRY
  #   seconds until a reply that gives GUEST_IP's link-layer address to HOST_MAC comes,
  #   for at most LEASE_SECONDS, which is how long the lease may take after the boot's
  #   last line;
  # * ICMP: an echo request to that address, answered by an echo reply from GUEST_IP
  #   with the request's identifier, sequence number and data, within REPLY_SECONDS.
  #
  # The exchange runs as the verifier of the boot transcript's last checkpoint, so QEMU
  # runs throughout and the run's deadline covers it. Every frame the harness reads is
  # parsed with bounds checks, since the guest is the code under test; a frame that is
  # not the awaited answer, slirp's included, is skipped.
  module NetDevice
    GUEST_IP = [10, 0, 2, 15].freeze
    HOST_IP = [10, 0, 2, 100].freeze
    HOST_MAC = [0x02, 0, 0, 0, 0, 0x01].freeze
    BROADCAST = [0xff] * 6
    ETHERTYPE_ARP = 0x0806
    ETHERTYPE_IP = 0x0800
    LEASE_SECONDS = 60
    REPLY_SECONDS = 5
    ARP_RETRY = 0.5
    PING_ID = 0xe1
    PING_SEQ = 1
    PING_DATA = 'erxos net-device ping'.b
    FRAME_BYTES = 2048
    SERIAL_BYTES = 1 << 20

    module_function

    def arp_request
      ethernet(BROADCAST, ETHERTYPE_ARP,
               [1, ETHERTYPE_IP, 6, 4, 1].pack('nnCCn') + bytes(HOST_MAC) + bytes(HOST_IP) +
               bytes([0] * 6) + bytes(GUEST_IP))
    end

    # The guest's link-layer address from an ARP reply to the harness, or nil.
    def arp_answer(frame)
      return nil unless frame.bytesize >= 42 && frame.unpack1('@12n') == ETHERTYPE_ARP

      _htype, _ptype, _hlen, _plen, op = frame.unpack('@14nnCCn')
      sender, sender_ip, target, target_ip = frame.unpack('@22a6a4a6a4')
      return nil unless op == 2 && sender_ip == bytes(GUEST_IP) && target == bytes(HOST_MAC) && target_ip == bytes(HOST_IP)

      sender
    end

    def echo_request(guest_mac)
      icmp = with_checksum([8, 0, 0, PING_ID, PING_SEQ].pack('CCnnn') + PING_DATA, at: 2)
      header = [0x45, 0, 20 + icmp.bytesize, 0, 0, 64, 1, 0].pack('CCnnnCCn') + bytes(HOST_IP) + bytes(GUEST_IP)
      ethernet(guest_mac.bytes, ETHERTYPE_IP, with_checksum(header, at: 10) + icmp)
    end

    # Whether a frame is the guest's echo reply to echo_request.
    def echo_answer?(frame)
      return false unless frame.bytesize >= 34 && frame.unpack1('@12n') == ETHERTYPE_IP

      version_ihl, total, protocol, source, destination = frame.unpack('@14C@16n@23C@26a4a4')
      header = (version_ihl & 0x0f) * 4
      return false unless version_ihl >> 4 == 4 && header >= 20 && protocol == 1 && total >= header + 8 &&
                          frame.bytesize >= 14 + total && source == bytes(GUEST_IP) && destination == bytes(HOST_IP)

      icmp = frame.byteslice(14 + header, total - header)
      type, code, _sum, id, seq = icmp.unpack('CCnnn')
      type.zero? && code.zero? && id == PING_ID && seq == PING_SEQ && icmp.byteslice(8..) == PING_DATA
    end

    def ethernet(destination, type, payload) = bytes(destination) + bytes(HOST_MAC) + [type].pack('n') + payload

    def bytes(list) = list.pack('C*')

    # The Internet checksum (RFC 1071) of data, written big-endian at offset at.
    def with_checksum(data, at:)
      words = (data.bytesize.odd? ? data + "\0".b : data).unpack('n*')
      sum = words.sum
      sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
      data.dup.tap { |out| out[at, 2] = [~sum & 0xffff].pack('n') }
    end

    # The harness's end of the hub: a loopback UDP socket QEMU's dgram backend sends to.
    class Link
      def initialize
        @socket = UDPSocket.new
        @socket.bind('127.0.0.1', 0)
        @frames_port = free_port
      end

      def nic = QemuPlan::Nic.new(frames_port: @frames_port, peer_port: @socket.addr[1])

      def close = @socket.close

      def send(frame) = @socket.send(frame, 0, '127.0.0.1', @frames_port)

      # The first frame for which block answers non-nil within seconds, else nil.
      def await(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if left <= 0
          next unless @socket.wait_readable(left)

          frame, = @socket.recvfrom(NetDevice::FRAME_BYTES)
          found = yield frame.b
          return found if found
        end
      end

      private

      def free_port
        probe = UDPSocket.new
        probe.bind('127.0.0.1', 0)
        probe.addr[1]
      ensure
        probe&.close
      end
    end

    # The ARP and ICMP exchange; raises Erx::Error naming the step the guest missed.
    def exchange(link)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LEASE_SECONDS
      guest_mac = nil
      while guest_mac.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        link.send(arp_request)
        guest_mac = link.await(ARP_RETRY) { |frame| arp_answer(frame) }
      end
      raise Error, "the guest answered no ARP request for #{GUEST_IP.join('.')} in #{LEASE_SECONDS} s" unless guest_mac

      link.send(echo_request(guest_mac))
      raise Error, 'the guest answered no ICMP echo request' unless link.await(REPLY_SECONDS) { |frame| echo_answer?(frame) }

      { mac: guest_mac.unpack('C*').map { |byte| format('%02x', byte) }.join(':') }
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @notes = []
      end

      # Boots the development image with a network device under each accelerator and
      # runs the exchange. Returns { "<accelerator>-1cpu" => 'passed' }; a guest that
      # misses a step raises.
      def call(accels:, jobs: 4, build: true)
        raise Error, 'the network device suite runs under tcg or hvf' unless accels.all? { |accel| %w[tcg hvf].include?(accel) }

        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/net-device/image'))
        image = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                               .build(directory: directory).single
        accels.to_h { |accel| ["#{accel}-1cpu", boot(accel, image)] }
      end

      def notes = @notes.dup.freeze

      private

      def boot(accel, image)
        directory = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/net-device',
                                                                          "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"),
                                            mode: 0o700)
        link = Link.new
        answered = nil
        *head, last = Qemu.boot_transcript(memory_mib: ProductionImage::MEMORY_MIB)
        verified = last.merge(seconds: last.fetch(:seconds) + LEASE_SECONDS + REPLY_SECONDS,
                              verify: ->(_line) { answered = NetDevice.exchange(link) }).freeze
        Qemu.new(root: @root, runner: @runner).run(accel: accel, image: image, memory_mib: ProductionImage::MEMORY_MIB,
                                                   directory: directory, checkpoints: [*head, verified], nic: link.nic,
                                                   command_line: ProductionImage::Run::COMMAND_LINES[accel])
        @notes << "#{accel}: the guest at #{GUEST_IP.join('.')} (#{answered.fetch(:mac)}) answered ARP and ICMP echo"
        'passed'
      ensure
        link&.close
      end
    end
  end
end
