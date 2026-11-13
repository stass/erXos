# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'io/console'
require 'optparse'
require 'shellwords'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # `tools/erx boot`: builds the development boot image the QEMU harness boots
  # and runs it in QEMU with the guest's serial line on this terminal, so a
  # person can type at the Erlang shell. Reading the arguments, choosing the
  # accelerator and planning QEMU's argument vector are pure; building the
  # image and running QEMU are the effects at the edge.
  #
  # The image builds into one directory of the tree's build/, which each boot
  # replaces, so two boots of one tree at once would build over each other,
  # and the second would remove the first's host link socket.
  #
  # With --hostlink the guest also gets what the host tools need of it: its
  # host link's UART on a UNIX socket in an owner-only directory of build/,
  # where `tools/erx web`, `load` and `files` connect, and the image's release
  # medium as its disk, so the storage domain serves /data and root's session
  # has its data. The medium is written fresh with each build, so /data starts
  # empty at every boot.
  module InteractiveBoot
    DIRECTORY = 'build/production-image/interactive'
    # Where --without-web builds the website's image, apart from DIRECTORY, so a later
    # development boot never replaces the image tools/build_site.rb publishes.
    SITE_DIRECTORY = 'build/production-image/site'
    QUIT_HINT = 'quit QEMU with Ctrl-A then X'
    # How long QEMU has to exit after SIGTERM before it is killed.
    STOP_SECONDS = 10
    DEFAULT_JOBS = 4
    # The host link socket's directory, emptied and made owner-only at each boot.
    HOSTLINK_DIRECTORY = 'build/production-image/hostlink'

    # What the person asked for. A nil accel asks for this host's best.
    Request = Data.define(:accel, :cpus, :jobs, :hostlink, :without_web)
    # The host link's socket and the medium the guest boots with, both absolute.
    Link = Data.define(:socket, :medium)
    # What a boot runs: the image's boot file, and its Link or nil.
    Boot = Data.define(:image, :link)

    module_function

    # The request the command-line arguments make. Raises OptionParser's
    # errors, which `tools/erx` reports as a usage error, before anything runs.
    def request(arguments)
      arguments = arguments.dup
      options = { accel: nil, cpus: 1, jobs: DEFAULT_JOBS, hostlink: false, without_web: false }
      OptionParser.new do |flags|
        flags.on('--accel NAME', %w[tcg hvf], 'Guest accelerator') { |value| options[:accel] = value }
        flags.on('--cpus N', Integer, 'Guest CPUs') { |value| options[:cpus] = value }
        flags.on('--jobs N', Integer, 'Build jobs') { |value| options[:jobs] = value }
        flags.on('--hostlink', 'Host link socket and data medium') { options[:hostlink] = true }
        flags.on('--without-web', 'Build the website\'s image, from its manifest without the web domain') { options[:without_web] = true }
      end.parse!(arguments)
      raise OptionParser::InvalidArgument, 'unexpected arguments' unless arguments.empty?
      if options.fetch(:hostlink) && options.fetch(:without_web)
        raise OptionParser::InvalidArgument, '--without-web leaves out the web domain that --hostlink serves'
      end
      unless QemuPlan::CPUS.cover?(options.fetch(:cpus))
        raise OptionParser::InvalidArgument, "--cpus must be between #{QemuPlan::CPUS.min} and #{QemuPlan::CPUS.max}"
      end
      # Fiasco#build's own bound, checked here so a bad count is a usage error.
      raise OptionParser::InvalidArgument, '--jobs must be between 1 and 64' unless options.fetch(:jobs).between?(1, 64)

      Request.new(**options)
    end

    # HVF where this host's QEMU offers it, else TCG. available is the set
    # QemuGate.available_accelerators reads from `qemu-system-aarch64 -accel help`.
    def default_accel(available) = available.include?('hvf') ? 'hvf' : 'tcg'

    # QEMU's argument vector for platform's board: the harness's own plan, with
    # memory_mib of RAM (the machine the image was packed for, machine), the kernel
    # command line its boots of this image use, and the serial line on
    # this terminal in place of a file. With a link, the host link's UART
    # listens on its socket, without waiting for a client, and the medium is the
    # guest's disk; without one, the UART is QEMU's null device and there is no disk.
    def argv(platform:, accel:, cpus:, image:, memory_mib:, link: nil)
      QemuPlan.argv(platform: platform, accel: accel, cpus: cpus, image: image, serial: QemuPlan::CONSOLE,
                    memory_mib: memory_mib, command_line: ProductionImage::Run::COMMAND_LINES[accel],
                    hostlink: link&.socket, disks: link ? [QemuPlan::Disk.new(path: link.medium)] : [])
    end

    # The command a person runs in another terminal to see the guest's web
    # view; program is tools/erx's own path, so it runs from any directory.
    def web_command(program, socket) = Shellwords.join([program, 'web', '--socket', socket])

    # The directory under the tree's root an image builds into: SITE_DIRECTORY for the
    # website's image, else DIRECTORY.
    def image_directory(without_web:) = without_web ? SITE_DIRECTORY : DIRECTORY

    # Builds the kernel and the image into DIRECTORY under root, replacing the
    # image an earlier boot left there, and returns the path of its boot file.
    def build_image(root:, runner:, jobs:, platform:, **tools)
      build(root: root, runner: runner, jobs: jobs, hostlink: false, platform: platform, **tools).image
    end

    # The system manifest the image is built from, as checked in for platform's board:
    # the website's manifest, which has no web domain, when without_web, else the development manifest.
    def manifest_source(root:, platform:, without_web:)
      without_web ? platform.site_manifest_source(root) : platform.manifest_source(root)
    end

    # The machine the image is packed and checked on, and boots on: the website's
    # (Machine.site, the RAM the website gives its guest) when without_web, else the
    # development machine.
    def machine(platform:, without_web:)
      without_web ? ProductionImage::Machine.site(platform) : ProductionImage::Machine.development(platform)
    end

    # Builds the kernel and the image into its directory under root, replacing the
    # image an earlier boot left there. With hostlink, the image's release
    # medium is written beside it, and HOSTLINK_DIRECTORY under root is first
    # emptied of any socket an earlier boot left, made owner-only, and its
    # socket path checked, so a path QEMU cannot take fails before the build.
    # With without_web the image is the website's (manifest_source).
    def build(root:, runner:, jobs:, hostlink:, platform:, without_web: false, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
      socket = hostlink_socket(root) if hostlink
      fiasco = Fiasco.new(root: root, runner: runner, compiler: compiler)
      fiasco.build(jobs: jobs)
      directory = ProductionImage.clear_directory(root: root, path: File.join(root, image_directory(without_web: without_web)))
      image_builder = ProductionImage.new(root: root, runner: runner, compiler: compiler, linker: linker,
                                          machine: machine(platform: platform, without_web: without_web), fiasco: fiasco)
      source = manifest_source(root: root, platform: platform, without_web: without_web)
      return Boot.new(image: image_builder.build(directory: directory, manifest_source: source).single, link: nil) unless socket

      built, written = image_builder.build_medium(directory: directory, manifest_source: source)
      Boot.new(image: built.single, link: Link.new(socket: socket, medium: written.path))
    end

    def hostlink_socket(root)
      directory = ProductionImage.clear_directory(root: root, path: File.join(root, HOSTLINK_DIRECTORY))
      socket = File.join(OutputDirectory.prepare(root: root, path: directory, mode: 0o700), 'socket')
      QemuPlan.hostlink_arguments(socket) # raises on a path QEMU cannot take
      socket
    end

    # Runs argv on this process's terminal until it exits, and returns its
    # exit status, 1 when a signal ended it. It has no deadline: the person
    # at the terminal decides when it ends.
    #
    # Whatever ends this process first (an interrupt, SIGTERM, SIGHUP) stops
    # the child before it propagates, and the terminal's mode is put back as
    # it was, whatever the child left it in. Signals reach this thread only
    # while it waits for the child; one that arrives during the spawn or the
    # cleanup waits until the cleanup is done, so a second signal cannot cut
    # the stop short. A child that ignores SIGTERM therefore holds this
    # process for up to stop_seconds. Only a signal this process cannot
    # handle (SIGKILL, for one) leaves the child running.
    def run(argv, stop_seconds: STOP_SECONDS)
      Thread.handle_interrupt(Object => :never) do
        saved_mode = $stdin.tty? ? $stdin.console_mode : nil
        # The [program, argv0] form never goes through a shell, whatever argv holds.
        pid = Process.spawn([argv.first, argv.first], *argv.drop(1), close_others: true)
        status = Thread.handle_interrupt(Object => :immediate) { Process.wait2(pid).last }
        pid = nil # reaped; nothing left to stop
        status.exitstatus || 1
      ensure
        stop(pid, seconds: stop_seconds) if pid
        restore_mode(saved_mode) if saved_mode
      end
    end

    # SIGTERM, which QEMU answers by restoring the terminal and exiting, then
    # SIGKILL if it has not exited within seconds. Reaps the child. Only a
    # child not yet reaped is signalled, so a reused pid never is.
    def stop(pid, seconds:)
      return if Process.wait(pid, Process::WNOHANG)

      Process.kill('TERM', pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until Process.wait(pid, Process::WNOHANG)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill('KILL', pid)
          Process.wait(pid)
          return
        end
        sleep(0.1)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # A terminal that hung up has no mode to restore; the failure must not
    # replace the signal that is ending this process.
    def restore_mode(mode)
      $stdin.console_mode = mode
    rescue SystemCallError
      nil
    end
    private_class_method :hostlink_socket, :stop, :restore_mode
  end
end
