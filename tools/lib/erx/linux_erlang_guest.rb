# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'bench_measurement'
require_relative 'bench_system'
require_relative 'error'
require_relative 'json_input'
require_relative 'linux_guest'
require_relative 'native_bench'
require_relative 'newc_archive'
require_relative 'oracle'
require_relative 'oracle_container'
require_relative 'oracle_export'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'qemu'
require_relative 'side_lock'
require_relative 'xdomain_bench'

module Erx
  # Linux's Erlang guest in the comparison under HVF (docs/design-bench.md, "Linux's
  # Erlang guest"): stock OTP 29.1.2, as the Linux oracle builds it and its install export
  # brings it out (docs/design-host-oracle.md, "The install export"), on the kernel of
  # Linux's guest, with an initramfs whose /init (bench/linux/erlang_init.c) starts epmd,
  # an echo node and a client node that times the xdomain cells. The bench modules are
  # the ones erXos's image runs, compiled by the stock oracle's erlc on the host.
  #
  # The export is the output of a container's workload, so it is read only after
  # OracleExport.verify has checked it against its inventory, each member's bytes are
  # checked against the inventory's hash as they are packed, and its paths reach the
  # initramfs only at the prefix the guest's loader and ERTS ask for, through
  # NewcArchive's checks of every path.
  module LinuxErlangGuest
    FLAVOUR = 'jit'
    VERSION = '29.1.2'
    # Where the oracle installed OTP, so nothing is relocated: install/ of the export.
    PREFIX = OracleExport::GUEST_ROOT.delete_prefix('/')
    BEAMS = 'bench/ebin'
    INIT = 'bench/linux/erlang_init.c'
    OUTPUT = 'build/linux-erlang-guest'
    HOSTS = "127.0.0.1\tlocalhost\n"
    ECHO = "{erx_xdomain_echo,'bench_echo@127.0.0.1'}"
    INSTALL_COMMAND = "tools/erx oracle install --flavour #{FLAVOUR} --docker-context NAME".freeze
    # /init's deadline for the client: two nodes' start and the cells' samples, with room.
    DEADLINE_SECONDS = 120
    # The identity line the client prints first (erx_bench_hist:main/1).
    IDENTITY = /\AERX_ORACLE /n
    SEEN = /\AERX_ORACLE ([0-9][0-9.]{0,15}) ([a-z]{1,8})\z/n
    # A 64-bit little-endian ELF file, its program headers' size, and the type of the one
    # that names the program's interpreter, the dynamic loader the kernel maps with it.
    ELF64_LE = "\x7fELF\x02\x01".b.freeze
    ELF_HEADER_BYTES = 64
    PROGRAM_HEADER_BYTES = 56
    PT_INTERP = 3
    INTERPRETER = %r{\A/[A-Za-z0-9._+/-]{1,254}\z}n
    # A verified install export: its directory, its inventory and the oracle's result.
    Export = Data.define(:directory, :inventory, :result)

    module_function

    # The newest install export of FLAVOUR whose workload completed with its mandatory
    # evidence, verified against its inventory; nil when there is none.
    def find_export(root:)
      complete = OracleContainer.results(root: root, flavour: FLAVOUR, operation: 'install').filter_map do |path|
        result = JsonInput.parse(File.binread(path, 1 << 20), max_bytes: 1 << 20, label: 'oracle result')
        [path, result] if result['state'] == 'completed' &&
                          result.dig('artifacts', 'mandatory_evidence') == 'complete'
      end
      path, result = complete.max_by { |candidate, _| File.mtime(candidate) }
      return nil if path.nil?

      directory = File.join(File.dirname(path), OracleContainer::WORKSPACE)
      Export.new(directory: directory, inventory: OracleExport.verify(destination: directory), result: result)
    end

    # The export's one ERTS bin directory, as the guest sees it.
    def bindir(inventory)
      directories = inventory.fetch('files').filter_map do |file|
        directory, name = OracleExport::INSTALL_PROGRAM_PATH.match(file.fetch('path'))&.captures
        directory if name == 'erlexec'
      end
      raise Error, "linux's Erlang guest: the export has no single ERTS directory" unless directories.one?

      "/#{PREFIX}/#{directories.first}"
    end

    # Where an export path lies in the guest: the tree at its installed prefix, and each
    # library at the path its loader listed.
    def guest_path(path)
      return "#{PREFIX}/#{path}" if path.start_with?('install/')
      return path.delete_prefix('libraries/') if path.start_with?('libraries/')

      raise Error, "linux's Erlang guest: the export holds #{path.inspect}, neither tree nor library"
    end

    def program?(path) = OracleExport::INSTALL_PROGRAMS.include?(OracleExport::INSTALL_PROGRAM_PATH.match(path)&.[](2))

    # The interpreter a program's PT_INTERP header names, or nil for a program without
    # one. Anything but one well-formed header inside the file refuses the program.
    def interpreter(data)
      refuse = ->(why) { raise Error, "linux's Erlang guest: a program #{why}" }
      refuse.call('is not a 64-bit little-endian ELF file') unless
        data.bytesize >= ELF_HEADER_BYTES && data.start_with?(ELF64_LE)
      table, size, count = data.unpack('Q<x14S<S<', offset: 32)
      refuse.call('has a malformed program header table') unless
        size == PROGRAM_HEADER_BYTES && table + (count * size) <= data.bytesize
      found = (0...count).map { |index| data.unpack('L<x4Q<x16Q<', offset: table + (index * size)) }
                         .select { |type, _, _| type == PT_INTERP }
      return nil if found.empty?

      refuse.call('names more than one interpreter') unless found.one?
      _, offset, length = found.first
      refuse.call('names its interpreter outside the file') unless offset + length <= data.bytesize
      name = data.byteslice(offset, length).delete_suffix("\0")
      refuse.call('names a malformed interpreter') unless INTERPRETER.match?(name)
      name
    end

    # The initramfs's entries: files, each export path and its bytes, at its guest path;
    # init; the bench modules' beams by name; /etc/hosts and the directories and devices
    # the kernel and ERTS need. Execute bits are derived, not recorded: /init, the five
    # programs of the export's ERTS directory, and the interpreter they name, which the
    # kernel executes with them, get them.
    def entries(files:, init:, beams:)
      programs = files.select { |path, _| program?(path) }
      interpreters = programs.filter_map { |_, data| interpreter(data)&.delete_prefix('/') }.uniq
      members = files.map { |path, data| [guest_path(path), data] }
      missing = interpreters - members.map(&:first)
      raise Error, "linux's Erlang guest: the export holds no #{missing.first}, which its programs name" unless
        missing.empty?

      runnable = programs.map { |path, _| guest_path(path) } + interpreters
      entries = members.map do |path, data|
        NewcArchive::Entry.file(path, data, mode: runnable.include?(path) ? 0o755 : 0o644)
      end
      entries += beams.map { |name, data| NewcArchive::Entry.file("#{BEAMS}/#{name}.beam", data, mode: 0o644) }
      entries += [NewcArchive::Entry.file('init', init, mode: 0o755), NewcArchive::Entry.file('etc/hosts', HOSTS.b, mode: 0o644),
                  NewcArchive::Entry.character('dev/console', major: 5, minor: 1),
                  NewcArchive::Entry.character('dev/null', major: 1, minor: 3), NewcArchive::Entry.directory('proc'),
                  NewcArchive::Entry.directory('sys'), NewcArchive::Entry.directory('tmp', mode: 0o1777)]
      parents = entries.flat_map { |entry| ancestors(entry.path) }.uniq - entries.map(&:path)
      (parents.map { |path| NewcArchive::Entry.directory(path) } + entries).sort_by(&:path)
    end

    # Each directory above path: "a/b/c" has "a" and "a/b".
    def ancestors(path)
      parts = path.split('/')
      (1...parts.size).map { |count| parts.first(count).join('/') }
    end

    # The refusal of a boot whose identity line is not VERSION in FLAVOUR, naming what was
    # seen as far as it has the line's shape; nil for the expected line.
    def identity_refusal(serial)
      found = serial.b.split(/\r?\n/n).grep(IDENTITY)
      return "the guest printed #{found.size} ERX_ORACLE lines" unless found.one?
      return nil if found.first == "ERX_ORACLE #{VERSION} #{FLAVOUR}".b

      seen = SEEN.match(found.first)
      seen ? "the guest's OTP is #{seen[1]} #{seen[2]}, not #{VERSION} #{FLAVOUR}" : 'the guest\'s ERX_ORACLE line is malformed'
    end

    # The client's one argument: benchmark's guest module and its arguments, its echo on
    # the peer node.
    def guests(asked) = XdomainBench.guests(asked, echo: ECHO)

    # What the boot asks: the xdomain boot's cells, on ERTS's monotonic clock.
    def asked(benchmark) = XdomainBench.asked([benchmark]).with(clock: 'monotonic')

    # The ERTS schedulers both nodes run at cpus CPUs (erl's +S), one per CPU,
    # passed so the record states what ran.
    def schedulers(cpus) = "#{cpus}:#{cpus}"

    # The kernel's command line: init's two arguments, the client's term and the nodes'
    # scheduler count.
    def command_line(asked, cpus:) = "#{LinuxGuest::COMMAND_LINE} -- #{guests(asked)} #{cpus}"

    # Builds the initramfs from export's tree and libraries, the members the guest runs,
    # in directory; the export's logs and evidence stay out. seeded are /init's seeded
    # fault's flags. Answers the kernel, the initramfs and the subject facts a record
    # keeps.
    def build(root:, runner:, export:, directory:, seeded: [])
      raise Error, "linux's Erlang guest needs the oracle's install export: run `#{INSTALL_COMMAND}`" if export.nil?

      dependencies = LinuxGuest.lock(root: root, runner: runner)
      flags = ["-DERX_INIT_DEADLINE_S=#{DEADLINE_SECONDS}u", %(-DERX_INIT_ROOTDIR="/#{PREFIX}/install/lib/erlang"),
               %(-DERX_INIT_BINDIR="#{bindir(export.inventory)}"), %(-DERX_INIT_BEAMS="/#{BEAMS}"), *seeded]
      init = LinuxGuest.compile(root: root, usr: dependencies.fetched_tree(LinuxGuest::MUSL_DEV), output: directory,
                                runner: runner, source: INIT, flags: flags)
      beams = compile_beams(root: root, runner: runner, output: directory)
      packed = export.inventory.fetch('files').select { |file| file.fetch('path').start_with?('install/', 'libraries/') }
      files = packed.map { |file| [file.fetch('path'), member(export.directory, file)] }
      initrd = File.join(directory, 'initramfs.cpio')
      File.binwrite(initrd, NewcArchive.write(entries(files: files, init: File.binread(init), beams: beams)))
      { kernel: dependencies.fetched_file(LinuxGuest::KERNEL), initrd: initrd,
        subject: subject(dependencies: dependencies, export: export, packed: packed, initrd: initrd, init: init,
                         beams: beams) }
    end

    # The bytes of an export member, which must be those its inventory hashed.
    def member(directory, file)
      data = File.binread(File.join(directory, file.fetch('path')))
      raise Error, "linux's Erlang guest: #{file.fetch('path')} changed since its export" unless
        Digest::SHA256.hexdigest(data) == file.fetch('sha256')

      data
    end

    # What a record says the guest ran: the pinned kernel and its command line, the
    # initramfs and /init, the OTP tree as its members' paths and hashes, the image that
    # built it, each library and each beam.
    def subject(dependencies:, export:, packed:, initrd:, init:, beams:)
      tree, libraries = packed.partition { |file| file.fetch('path').start_with?('install/') }
      { 'kernel' => dependencies.sources.find { |source| source.fetch('id') == LinuxGuest::KERNEL }.slice('id', 'version', 'sha256'),
        'command_line' => LinuxGuest::COMMAND_LINE, 'initramfs_sha256' => Digest::SHA256.file(initrd).hexdigest,
        'init_sha256' => Digest::SHA256.file(init).hexdigest,
        'otp' => "#{VERSION} #{FLAVOUR}",
        'otp_tree_sha256' => Digest::SHA256.hexdigest(JSON.generate(tree.map { |file| file.slice('path', 'sha256') })),
        'toolchain_image' => export.result.dig('image', 'manifest_sha256'),
        'libraries' => libraries.to_h { |file| [file.fetch('path'), file.fetch('sha256')] },
        'beams' => beams.transform_values { |data| Digest::SHA256.hexdigest(data) } }
    end

    # The bench modules compiled by the stock oracle's erlc, as stock OTP loads them.
    def compile_beams(root:, runner:, output:)
      directory = File.join(output, 'ebin').tap { |path| Dir.mkdir(path) }
      Oracle.new(root: root).with_runtime(FLAVOUR) do |oracle|
        runner.run([oracle.fetch('erlc'), '+warnings_as_errors', '-o', directory,
                    *XdomainBench::MODULES.map { |name| File.join(root, 'bench', "#{name}.erl") }],
                   name: 'linux-erlang-erlc', deadline: 120, clear_env: true, env: { 'PATH' => '/usr/bin:/bin' })
      end
      XdomainBench::MODULES.to_h { |name| [name, File.binread(File.join(directory, "#{name}.beam"))] }
    end

    # One boot of the guest at cpus CPUs for asked, its serial log in directory.
    def boot(root:, runner:, built:, asked:, cpus:, accel:, directory:)
      checkpoints = [{ name: 'oracle-identity', pattern: IDENTITY, seconds: 60 },
                     { name: 'bench-done', pattern: /\Aerx: bench: done/n,
                       seconds: DEADLINE_SECONDS + NativeBench::DEADLINE_MARGIN_SECONDS }]
      Qemu.new(root: root, runner: runner).run(
        platform: Platform.development(root), accel: accel, cpus: cpus, memory_mib: NativeBench::MEMORY_MIB,
        image: built.fetch(:kernel), initrd: built.fetch(:initrd), hostlink: QemuPlan::NO_HOSTLINK,
        command_line: command_line(asked, cpus: cpus), checkpoints: checkpoints, machine_end: true,
        directory: directory
      )
    end
    private_class_method :ancestors, :member, :subject, :compile_beams

    # Linux's Erlang guest of the xdomain boot in a comparison session (BenchSystem): one
    # boot of the kernel and the initramfs, built once per session at its first boot in a
    # directory removed when the session ends, its lines judged as erXos's xdomain
    # guest's are, in clock monotonic. A boot whose identity line is not stock OTP 29.1.2
    # in FLAVOUR has every cell rejected.
    class Guest
      def initialize(root:, runner:)
        @root = File.expand_path(root)
        @runner = runner
      end

      def system = 'linux'
      def boot = XdomainBench::BOOT
      def forms(cpus) = [1, cpus].uniq

      def refusal(profile)
        return "linux's Erlang guest is built with the landing profiles only" unless profile == 'landing'

        LinuxGuest::Guest.new(root: @root, runner: @runner).refusal(profile) ||
          (LinuxErlangGuest.find_export(root: @root) ? nil : "linux's Erlang guest needs the oracle's install export: " \
                                                              "run `#{INSTALL_COMMAND}`")
      end

      def call(benchmark, cells:, cpus:, accel:)
        asked = LinuxErlangGuest.asked(benchmark)
        directory = File.join(@root, 'build/qemu', "linux-erlang-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = LinuxErlangGuest.boot(root: @root, runner: @runner, built: built, asked: asked, cpus: cpus, accel: accel,
                                       directory: directory)
        # The kernel QEMU booted is the pinned one, as the record says.
        unless report.fetch('image_sha256') == built.fetch(:subject).fetch('kernel').fetch('sha256')
          raise Error, "#{built.fetch(:kernel)} is not the kernel Linux's lock pins: " \
                       "run `#{SideLock.fetch_command(LinuxGuest::LABEL)}`"
        end
        serial = report.fetch('serial_log')
        log = File.binread(serial)
        refusal = LinuxErlangGuest.identity_refusal(log)
        answer = BenchMeasurement.boot(NativeBench.guest_lines(log), asked)
        answer = answer.merge(clock: nil, cells: BenchMeasurement.rejected(asked, reason: refusal), refused: [refusal]) if refusal
        BenchSystem::Booted.new(
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
          environment: { 'memory_mib' => NativeBench::MEMORY_MIB, 'machine' => 'virt', 'qemu' => report['qemu_version'],
                         'erts_schedulers' => LinuxErlangGuest.schedulers(cpus) }.compact,
          subject: built.fetch(:subject), logs: [{ serial: serial }], reused_from: report['reused_from']
        )
      end

      private

      # The kernel and the initramfs, built at the first boot into a directory of the
      # session's own that it removes when the process ends.
      def built
        @built ||= begin
          parent = OutputDirectory.prepare(root: @root, path: File.join(@root, OUTPUT))
          directory = Dir.mktmpdir("build-#{Process.pid}-", parent)
          at_exit { FileUtils.rm_rf(directory) }
          LinuxErlangGuest.build(root: @root, runner: @runner, export: LinuxErlangGuest.find_export(root: @root),
                                 directory: directory)
        end
      end
    end
  end
end
