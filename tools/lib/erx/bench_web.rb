# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'rbconfig'
require 'socket'
require 'time'
require 'tmpdir'
require_relative 'bench'
require_relative 'error'
require_relative 'fiasco'
require_relative 'hostlink_guest'
require_relative 'hostlink_pacer'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'release_medium'
require_relative 'runner'
require_relative 'session_domain'
require_relative 'web_build'
require_relative 'web_guest'

module Erx
  # Gate GW (docs/plan.md, "Gate GW"): a record view's round trip over the host tool's
  # front end, tools/erx web, for the machine's record and for root's session's
  # processes, a listing of WebGuest::IDLE_PROCESSES children. One 1-CPU HVF boot of the
  # production image does it: the console logs root in, root's session's Erlang shell
  # starts the idle processes, as the session_domain suite's last session does, and the
  # host then serves the front end twice, once straight on the guest's host link socket
  # and once through a HostlinkPacer at a 115,200-baud UART's 11,520 bytes a second each
  # way. A scripted browser, WebGuest's, opens each view OPENS times, each a view number
  # of its own that it closes once answered, and times the open's binary frame until the
  # update's whole frame arrives. The client goes through the front end, not straight to
  # the host link, because the front end's relaying is part of what a browser waits for.
  # The report is build/bench/web-hvf-*/result.json.
  class BenchWeb
    OPENS = 21
    # 115,200 baud with 8N1 framing: ten bits on the line for each byte.
    UART_BYTES_PER_SECOND = 11_520
    # Each link the front end is measured over: nil is the host link socket itself.
    LINKS = { 'unpaced' => nil, 'uart' => UART_BYTES_PER_SECOND }.freeze
    # Each view's path in /proc, and the kind of the record that answers its open.
    Target = Data.define(:names, :kind)
    TARGETS = { 'machine' => Target.new(names: [], kind: 'machine'),
                'processes' => Target.new(names: ['processes'], kind: 'listing') }.freeze
    # The pause after each answered open, so the view's close has crossed the line before
    # the next open is timed.
    PAUSE_SECONDS = 0.5
    # The worst case of the link's work: the first check of the machine's record, then for
    # each link the front end's URL, the login's connection and answer, and its stop; the
    # WebSocket's upgrade and welcome; and each open's wait for its answer and its pause.
    LINK_SECONDS = (HostlinkGuest::WEB_SECONDS * 2) +
                   (LINKS.size * ((WebGuest::STEP_SECONDS * 4) + (HostlinkGuest::WEB_SECONDS * 2) +
                                  (TARGETS.size * OPENS * (HostlinkGuest::WEB_SECONDS + PAUSE_SECONDS.ceil))))
    UPDATE = 2
    ENDED = 3
    CLOSE = 4

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
      @root = File.realpath(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
    end

    # Builds the production image and the web client, boots the image and writes the
    # report however far the boot got.
    def run(jobs: 4)
      fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
      fiasco.build(jobs: jobs)
      WebBuild.build(root: @root, runner: @runner)
      manifest = File.binread(File.join(@root, ProductionImage::MANIFEST))
      directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/bench-web/image'))
      built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                      .build_medium(directory: directory, machine: SessionDomain::MACHINE, manifest_source: manifest)
      bench = Bench.new(root: @root, runner: @runner)
      before = bench.load_average
      qemu, failure = boot(built, written, manifest)
      write(self.class.report(host: bench.host_description, now: Time.now.utc, qemu: qemu, failure: failure,
                              load: { 'before' => before, 'after' => bench.load_average }))
    end

    # The production checkpoints to the system's command shell, then root's session's
    # command shell, its Erlang shell, and the idle processes started there.
    def self.checkpoints(points)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points,
       SessionDomain.session_shell('root_1-shell', ProductionImage::Run::ERL_LINE),
       ProductionImage::Run::ERLANG_SHELL.merge(name: 'root_1-erlang-shell', type: SessionDomain::IDLE_PROCESSES).freeze,
       { name: 'idle-processes', pattern: SessionDomain.answer('ok'), seconds: 60 }.freeze].freeze
    end

    # The report: for each link and target, the round trips' median and 95th percentile
    # in milliseconds and the updates' sizes, and over the paced link the host link's
    # bytes each way per round trip. Pure.
    def self.report(host:, now:, qemu:, failure:, load:)
      links = qemu&.fetch('link', nil) || {}
      { 'benchmark' => 'web', 'host' => host, 'accelerator' => 'hvf', 'cpus' => 1, 'measured_at' => now.iso8601,
        'qemu_version' => qemu&.fetch('qemu_version', nil), 'image_sha256' => qemu&.fetch('image_sha256', nil),
        'error' => failure&.message, 'host_load' => load, 'opens' => OPENS, 'idle_processes' => WebGuest::IDLE_PROCESSES,
        'uart_bytes_per_second' => UART_BYTES_PER_SECOND,
        'links' => links.transform_values { |targets| targets.transform_values { |samples| summary(samples) } },
        'complete' => failure.nil? && links.keys == LINKS.keys }
    end

    # One target's samples, each { seconds:, update_bytes:, to_host:, to_target: }, summed
    # up; the host link's counts are nil on the unpaced link, which counts nothing.
    def self.summary(samples)
      milliseconds = samples.map { |sample| (sample.fetch(:seconds) * 1000).round(1) }
      { 'median_ms' => percentile(milliseconds, 50), 'p95_ms' => percentile(milliseconds, 95),
        'samples_ms' => milliseconds,
        'update_bytes' => samples.map { |sample| sample.fetch(:update_bytes) }.minmax,
        'link_bytes_to_host' => median_link_bytes(samples, :to_host),
        'link_bytes_to_target' => median_link_bytes(samples, :to_target) }
    end

    # The nearest-rank percentile of values.
    def self.percentile(values, rank)
      sorted = values.sort
      sorted[((rank / 100.0) * sorted.size).ceil - 1]
    end

    # The median of a link count over the samples, or nil when the link counted none.
    def self.median_link_bytes(samples, key)
      values = samples.map { |sample| sample.fetch(key) }
      values.include?(nil) ? nil : percentile(values, 50)
    end

    private

    def boot(built, written, manifest)
      run = "web-hvf-#{Process.pid}-#{Random.bytes(4).unpack1('H*')}"
      directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(@root, 'build/bench-web', run))
      medium = ReleaseMedium.medium(written.slot, directory: directory, data_sectors: written.data_sectors, volume: written.volume)
      memory = SessionDomain::MACHINE.memory_mib
      points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                       manifest_source: manifest, memory_mib: memory)
      hash = HostlinkGuest.web_hash(@root)
      # The boot's directory holds the host link's socket, whose path must be short.
      qemu = Qemu.new(root: @root, runner: @runner)
                 .run(accel: 'hvf', cpus: 1, image: built.single, memory_mib: memory,
                      disks: [QemuPlan::Disk.new(path: medium)], checkpoints: self.class.checkpoints(points),
                      directory: File.join(@root, 'build/qemu', "bw-#{Process.pid}"),
                      link: ->(socket) { measure(socket, built.build_id, hash) }, link_seconds: LINK_SECONDS)
      [qemu, nil]
    rescue Error => e
      [nil, e]
    end

    # Once the machine's record answers straight over the host link, so root's line is up,
    # each link's round trips: { link => { target => [sample] } }.
    def measure(socket, build, hash)
      HostlinkGuest.machine(socket, build: build, web_hash: hash)
      views = (1..).each
      LINKS.to_h { |name, rate| [name, over_link(socket, build, hash, name: name, rate: rate, views: views)] }
    end

    # The front end on the guest's host link, straight when rate is nil and otherwise
    # through a pacer at rate bytes a second, and every target's round trips through it.
    def over_link(socket, build, hash, name:, rate:, views:)
      log = File.join(File.dirname(socket), "web-#{name}.log")
      if rate
        paced(socket, rate) do |path, pacer|
          front_end(path, build, log) { |url| browse(url, hash, views, log, pacer: pacer) }
        end
      else
        front_end(socket, build, log) { |url| browse(url, hash, views, log, pacer: nil) }
      end
    end

    # tools/erx web on the host link socket at path while the block runs with the URL
    # it printed.
    def front_end(path, build, log)
      pid = Process.spawn(RbConfig.ruby, File.join(@root, 'tools/erx'), 'web', '--socket', path, '--build', build,
                          in: :close, %i[out err] => [log, 'w'])
      begin
        yield URI(WebGuest.printed_url(log))
      ensure
        WebGuest.stop(pid)
      end
    end

    # A socket beside the guest's, paced.sock, whose one connection, the front end's, a
    # pacer relays to the guest's socket at rate; the block runs with its path and the
    # pacer. A paced.sock a killed run left behind is replaced. Closing the listener
    # ends a wait for a front end that never connected.
    def paced(socket, rate)
      path = File.join(File.dirname(socket), 'paced.sock')
      File.unlink(path) if File.socket?(path)
      listener = UNIXServer.new(path)
      pacer = HostlinkPacer.new(bytes_per_second: rate)
      relaying = Thread.new do
        Thread.current.report_on_exception = false
        pacer.relay(host: listener.accept, target: UNIXSocket.new(socket))
      end
      begin
        yield path, pacer
      ensure
        listener.close
        begin
          relaying.join
        rescue IOError, SystemCallError
          nil
        end
        pacer.close
        File.unlink(path) if File.socket?(path)
      end
    end

    # A browser's login and WebSocket, hello and welcome, then each target's round
    # trips; pacer is the link's, or nil on the unpaced link, which counts nothing.
    def browse(url, hash, views, log, pacer:)
      cookie = Net::HTTP.start(url.host, url.port, open_timeout: WebGuest::STEP_SECONDS,
                                                   read_timeout: WebGuest::STEP_SECONDS) { |http| WebGuest.login(http, url, log) }
      TCPSocket.open(url.host, url.port) do |io|
        frames = WebGuest.upgrade(io, url, cookie, log)
        io.write(WebGuest.browser_frame(HostlinkGuest.hello(hash)))
        welcome = frames.binary('the welcome')
        WebGuest.fail_with(log, "the welcome is #{welcome.unpack1('H*')}") unless welcome.getbyte(0) == HostlinkGuest::WELCOME
        TARGETS.transform_values { |target| Array.new(OPENS) { round_trip(io, frames, target, views.next, log, pacer: pacer) } }
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      WebGuest.fail_with(log, "HTTP to #{url.host}:#{url.port}: #{e.message}")
    end

    # One open of view on target, timed from its frame's write until the update's frame
    # is whole, with the host link's bytes each way meanwhile; then the view's close.
    def round_trip(io, frames, target, view, log, pacer:)
      before = pacer&.counts
      started = now
      io.write(WebGuest.browser_frame(WebGuest.open_path(view, target.names)))
      update = answer(frames, view, log)
      seconds = now - started
      after = pacer&.counts
      check_update(update, target, view, log)
      io.write(WebGuest.browser_frame([CLOSE, view].pack('CV')))
      sleep(PAUSE_SECONDS)
      { seconds: seconds, update_bytes: update.bytesize, to_host: after && (after[:to_host] - before[:to_host]),
        to_target: after && (after[:to_target] - before[:to_target]) }
    end

    # The next update of view; an earlier view's end, which its close may bring, is passed
    # over, and any other message fails.
    def answer(frames, view, log)
      loop do
        message = frames.binary("view #{view}'s update")
        tag = message.getbyte(0)
        number = message.byteslice(1, 4).to_s.unpack1('V')
        return message if tag == UPDATE && number == view
        next if tag == ENDED && number && number < view

        WebGuest.fail_with(log, "view #{view} was answered with #{message.byteslice(0, 96).unpack1('H*')}")
      end
    end

    # The update is target's record: the listing of processes is a partial page of the
    # idle processes (WebGuest.processes_page?), so the workload is the one the gate names.
    def check_update(update, target, view, log)
      whole = if target.kind == 'listing'
                WebGuest.processes_page?(update, view)
              else
                update.start_with?(WebGuest.record_update(view, target.names, target.kind))
              end
      WebGuest.fail_with(log, "view #{view}'s update is #{update.byteslice(0, 96).unpack1('H*')}") unless whole
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def write(report)
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      path = File.join(Dir.mktmpdir('web-hvf-', parent), 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      report.merge('report' => path)
    end
  end
end
