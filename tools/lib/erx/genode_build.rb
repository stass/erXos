# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'rubygems/package'
require 'securerandom'
require 'tmpdir'
require_relative 'dependencies'
require_relative 'error'
require_relative 'genode_fetch'
require_relative 'guest_build'
require_relative 'json_input'
require_relative 'oracle_container'
require_relative 'output_directory'
require_relative 'peer_bench'

module Erx
  # `tools/erx build genode` (docs/design-bench.md, "Genode's guest"): Genode's base-hw
  # kernel for QEMU's virt machine with erx_peer_bench as a component, built by Genode's
  # own tools inside the oracle's amd64 toolchain image, offline and as a non-root user,
  # and the boot image brought back with its build record. It runs on the x86-64 host
  # whose engine the docker context names by its local UNIX socket.
  #
  # Genode is AGPL-3.0 and a test oracle: its tree, its tool chain, its ports' archives
  # and the Debian tool packages are untrusted data that nothing on the host runs or
  # reads beyond the headers of the archives the engine extracts (check_archive). Its
  # run tool takes a Tcl script, which run_script writes from erXos's own values into the
  # container's inputs; no Tcl file is in erXos's tree.
  #
  # The decisions are pure (run_script, data_archive, check_archive, plan, record); build
  # runs the plan's docker commands and always removes the container and its work
  # directory.
  module GenodeBuild
    LABEL = "Genode's build"
    IMAGE_ID = 'oracle-toolchain-amd64'
    PLATFORM = 'linux/amd64'
    SCRIPT = 'bench/genode/build.sh'
    TARGET = 'bench/genode/target.mk'
    KERNEL = 'hw'
    BOARD = 'virt_qemu_arm_v8a'
    # The component's name: its target, its start node and its run script's.
    PROGRAM = 'erx_peer_bench'
    # What of erXos's tree the component's one C file includes, staged at its tree paths
    # (the program's directory, the bench guest's helpers and the one liberx header they
    # take), so its includes resolve as under the Linux guest's -I of the tree.
    SOURCES = %w[bench/peer test/guest/bench liberx/backend/core/mem.h].freeze
    # The component's RAM: the posix rows' two 16 MiB files and untar's extraction live in
    # its /tmp, a file system in its memory.
    PROGRAM_RAM = '192M'
    OUTPUT = 'build/genode'
    # What the container script leaves in /tmp/out, each with the most bytes it may hold.
    OUTPUTS = { 'image.elf' => 64 << 20, 'config' => 1 << 20, 'compiler' => 4096 }.freeze
    DEADLINE = 4 * 3600
    RUN_LOG_BYTES = 64 << 20
    ARCHIVE_BYTES = OUTPUTS.values.sum + (64 << 10)
    # The most bytes a tool archive may decompress to on the host for its check.
    UNPACKED_BYTES = 8 << 30
    # Where each archive the engine extracts at the container's root may write: Debian's
    # packages under usr/, the tool chain under its own install directory.
    PACKAGE_PREFIX = 'usr/'
    TOOLCHAIN_PREFIX = 'usr/local/genode/tool/'
    # tar's type flags check_archive accepts: regular file, hard link, symbolic link, directory.
    ENTRY_TYPES = { '0' => :file, "\0" => :file, '1' => :hard, '2' => :symbolic, '5' => :directory }.freeze
    # A name's leading "./" or "/": the engine extracts every name beneath the root it is
    # given, and the tool chain's archive names its entries from "/".
    LEADING = %r{\A\.?/}
    # GNU tar's long name ('L') and long link target ('K') entries, whose data is the next
    # entry's name or target, as the engine reads them too; each at most LONG_BYTES.
    LONG = { 'L' => :name, 'K' => :link }.freeze
    LONG_BYTES = 4096

    module_function

    # Genode's run script for erx_peer_bench given arguments: the depot's archives the
    # probe of Genode's tools built, the component built from erXos's target description,
    # and init's configuration in the notation Genode Foundations 26.05 documents ("The
    # init component"): the component's log on Genode's LOG, a /tmp in its memory.
    def run_script(arguments:)
      words = [PROGRAM, *arguments]
      raise Error, "#{LABEL}: program arguments must be words of letters, digits, '.', '_' or '-'" unless
        words.all? { |word| word.match?(/\A[A-Za-z0-9._-]+\z/) }

      <<~TCL
        create_boot_directory
        import_from_depot [depot_user]/src/[base_src] [depot_user]/src/init [depot_user]/src/libc \\
                          [depot_user]/src/vfs [depot_user]/src/posix
        build { app/#{PROGRAM} }
        install_config {
        config
        + parent-provides
          + service PD
          + service ROM
          + service CPU
          + service LOG
          + service IRQ
          + service IO_MEM
        + default-route
          + service Timer | + child timer
          + any-service | + parent
        + default | caps: 100
        + start timer | ram: 2M
          + provides | + service Timer
        + start #{PROGRAM} | ram: #{PROGRAM_RAM} | caps: 1000
          + config
            + vfs
              + dir dev | + log
              + dir tmp | + ram
            + libc | stdout: /dev/log | stderr: /dev/log
        #{words.map { |word| "      + arg | value: #{word}" }.join("\n")}
        -
        }
        build_boot_image [build_artifacts]
      TCL
    end

    # The data archive of the Debian package bytes: its data.tar.xz member, the one the
    # engine extracts. Neither the control archive nor any script of the package is taken.
    def data_archive(bytes)
      raise Error, "#{LABEL}: a tool package is not a Debian package (no ar header)" unless bytes.start_with?("!<arch>\n")

      offset = 8
      while offset + 60 <= bytes.bytesize
        header = bytes.byteslice(offset, 60)
        name = header.byteslice(0, 16).strip.delete_suffix('/')
        size = header.byteslice(48, 10).strip
        raise Error, "#{LABEL}: a tool package has a malformed ar member" unless
          header.byteslice(58, 2) == "`\n" && size.match?(/\A[0-9]{1,10}\z/) && offset + 60 + size.to_i <= bytes.bytesize
        return bytes.byteslice(offset + 60, size.to_i) if name == 'data.tar.xz'

        offset += 60 + size.to_i + (size.to_i & 1)
      end
      raise Error, "#{LABEL}: a tool package has no data.tar.xz"
    end

    # Refuses the tar read from io unless every entry is a directory, a regular file, or a
    # link whose target stays under prefix, and lies under prefix itself (or is the root
    # directory "./"): the engine extracts it at the container's root, so an entry
    # elsewhere, an absolute or ".." path, a device, or an extended header that renames an
    # entry would reach beyond the tools' directories. Returns the number of entries.
    def check_archive(io, prefix:, label:)
      long = {}
      Gem::Package::TarReader.new(io).sum do |entry|
        header = entry.header
        if LONG.key?(header.typeflag)
          raise Error, "#{label} holds a long name over #{LONG_BYTES} bytes" unless header.size <= LONG_BYTES
    
          long[LONG.fetch(header.typeflag)] = entry.read.to_s.delete_suffix("\0")
          next 0
        end
        type = ENTRY_TYPES[header.typeflag]
        name = long.delete(:name) || (header.prefix.empty? ? header.name : "#{header.prefix}/#{header.name}")
        target = long.delete(:link) || header.linkname
        path = name.sub(LEADING, '')
        root = type == :directory && ['', '.', './', '/'].include?(name)
        unless root || (type && under?(path, prefix) && (type == :file || type == :directory || link_inside?(type, path, target, prefix)))
          raise Error, "#{label} holds #{name.inspect} (type #{header.typeflag.inspect}), not a directory, file or " \
                       "link under ./#{prefix}"
        end
    
        1
      end
    rescue Gem::Package::Error
      raise Error, "#{label} is not a tar archive"
    end

    def under?(path, prefix)
      parts = path.split('/')
      path.start_with?(prefix) && !path.start_with?('/') && parts.none? { |part| ['.', '..'].include?(part) }
    end
    private_class_method :under?

    # A symbolic link resolves against its own directory, a hard link names an entry of
    # the archive; either target must stay under prefix.
    def link_inside?(type, path, target, prefix)
      return File.expand_path("/#{target.sub(LEADING, '')}").start_with?("/#{prefix}") if type == :hard
      return false if target.empty? || target.start_with?('/')

      File.expand_path(target, "/#{File.dirname(path)}").start_with?("/#{prefix}")
    end
    private_class_method :link_inside?

    # The docker commands of one build on the engine at endpoint: create the container,
    # inspect it, extract each tool archive (archives, each [host path, prefix]) at its
    # root, copy the tree to /tmp/<directory> with its two directories the build writes,
    # and the inputs to /tmp/inputs, run the script attached, and stream /tmp/out to
    # archive as a tar.
    def plan(endpoint:, name:, image:, inputs:, tree:, directory:, writable:, archives:, archive:, jobs:, toolchain:)
      docker = ['docker', '--host', endpoint]
      memory = "#{2 * jobs}g"
      environment = ['HOME=/tmp/home', "PATH=/usr/local/genode/tool/#{toolchain}/bin:/usr/local/bin:/usr/bin:/bin", 'LANG=C.UTF-8']
      genode = "/tmp/#{directory}"
      copy = ->(from, to) { GuestBuild::Step.new(name: 'genode-build-copy', argv: [*docker, 'cp', from, "#{name}:#{to}"]) }
      {
        create: GuestBuild::Step.new(name: 'genode-build-create', argv: [
          *docker, 'create', '--pull', 'never', '--platform', PLATFORM, '--name', name,
          *OracleContainer::CONFINEMENT, '--user', GuestBuild::USER, '--workdir', '/tmp', '--pids-limit', '4096',
          '--cpus', jobs.to_s, '--memory', memory, '--memory-swap', memory,
          '--entrypoint', '/usr/bin/env', image, '-i', *environment,
          '/usr/bin/timeout', '-k', '10', DEADLINE.to_s, '/bin/sh', '/tmp/inputs/build.sh', jobs.to_s, genode
        ]),
        inspect: GuestBuild::Step.new(name: 'genode-build-inspect', argv: [*docker, 'inspect', '--type', 'container', name,
                                                                           '--format', '{{json .}}'], limit: 1 << 20),
        extracts: archives.map do |path, _prefix|
          GuestBuild::Step.new(name: 'genode-build-extract', argv: [*docker, 'cp', '-', "#{name}:/"], stdin: path, deadline: 1800)
        end,
        copies: [copy.call(tree, genode), copy.call("#{writable}/.", genode), copy.call(inputs, '/tmp/inputs')],
        start: GuestBuild::Step.new(name: 'genode-build-run', argv: [*docker, 'start', '--attach', name],
                                    deadline: DEADLINE + 60, limit: RUN_LOG_BYTES),
        export: GuestBuild::Step.new(name: 'genode-build-export', argv: [*docker, 'cp', "#{name}:/tmp/out", '-'],
                                     limit: ARCHIVE_BYTES, stdout: archive)
      }
    end

    # The build record (docs/design-bench.md, "The record"): the pins of every source,
    # the image, the tool chain's compiler, the kernel and board, the program's arguments,
    # and the SHA-256 of the resolved run configuration and of the boot image.
    def record(sources:, image:, out:, arguments:)
      {
        'sources' => sources.to_h { |source| [source.fetch('id'), source.fetch('kind') == 'git' ? source.fetch('commit') : source.fetch('sha256')] },
        'image' => image, 'platform' => PLATFORM, 'kernel' => KERNEL, 'board' => BOARD,
        'compiler' => GuestBuild.text(out, 'compiler', label: LABEL).lines.first.to_s.strip,
        'compiler_flags' => "Genode's own for this board, and erx_peer_bench's (bench/genode/target.mk)",
        'arguments' => arguments,
        'config_sha256' => Digest::SHA256.hexdigest(GuestBuild.text(out, 'config', label: LABEL)),
        'image_sha256' => Digest::SHA256.file(File.join(out, 'image.elf')).hexdigest
      }
    end

    # Builds Genode's guest for a posix run on cpus CPUs on the engine of the docker
    # context, leaving image.elf, the configuration and the build record in build/genode.
    # Returns image.elf's path.
    def build(root:, runner:, context:, jobs:, cpus: 1)
      raise Error, 'Genode build jobs must be 1 to 64' unless jobs.is_a?(Integer) && jobs.between?(1, 64)

      dependencies = Dependencies.new(root: root, runner: runner, docker_context: context)
      endpoint = dependencies.local_docker_connection.fetch('endpoint')
      fetched = GenodeFetch.lock(root: root, runner: runner)
      image = dependencies.image_for(IMAGE_ID).fetch('reference')
      work = OutputDirectory.prepare(root: root, path: File.join(root, 'build/genode-work'))
      directory = Dir.mktmpdir('build-', work)
      arguments = PeerBench.arguments('posix', cpus: cpus)
      inputs = stage_inputs(root: root, fetched: fetched, directory: directory, arguments: arguments)
      writable = File.join(directory, 'writable')
      %w[contrib depot].each { |name| FileUtils.mkdir_p(File.join(writable, name)) && File.chmod(0o1777, File.join(writable, name)) }
      archives = stage_archives(runner: runner, fetched: fetched, directory: directory)
      genode = fetched.sources.find { |source| source.fetch('id') == 'genode' }
      toolchain = fetched.sources.find { |source| source.fetch('id') == 'genode-toolchain' }.fetch('version')
      name = "erx-genode-build-#{SecureRandom.hex(8)}"
      archive = File.join(directory, 'out.tar')
      steps = plan(endpoint: endpoint, name: name, image: image, inputs: inputs, tree: fetched.fetched_tree('genode'),
                   directory: genode.fetch('directory'), writable: writable, archives: archives, archive: archive,
                   jobs: jobs, toolchain: toolchain)
      run = ->(step) { GuestBuild.run(runner, step) }
      begin
        run.call(steps.fetch(:create))
        GuestBuild.check_container(JsonInput.parse(File.binread(run.call(steps.fetch(:inspect)).fetch('log')),
                                                   max_bytes: 1 << 20, label: "Genode's build container"), label: LABEL)
        steps.fetch(:extracts).each(&run)
        steps.fetch(:copies).each(&run)
        run.call(steps.fetch(:start))
        run.call(steps.fetch(:export))
      ensure
        # Also on an interrupt; a failed removal raises only when nothing else propagates.
        GuestBuild.remove(runner: runner, endpoint: endpoint, name: name, raising: $!.nil?)
      end
      out = File.join(directory, 'out')
      GuestBuild.unpack(archive: archive, out: out, outputs: OUTPUTS, label: LABEL)
      publish(root: root, out: out, record: record(sources: fetched.sources, image: image, out: out, arguments: arguments))
    ensure
      FileUtils.rm_rf(directory) if directory
    end

    # The container's /tmp/inputs: the script, each port's archive under ports/<port>/
    # with the name Genode's port tool asks for, and erXos's Genode repository: the
    # component's target description, its flags from their one source (PeerBench.flags),
    # the C files at their tree paths under its root/, and the run script.
    def stage_inputs(root:, fetched:, directory:, arguments:)
      inputs = File.join(directory, 'inputs')
      app = File.join(inputs, 'repo/src/app', PROGRAM)
      FileUtils.mkdir_p([app, File.join(inputs, 'repo/run')])
      FileUtils.copy_file(File.join(root, SCRIPT), File.join(inputs, 'build.sh'))
      FileUtils.copy_file(File.join(root, TARGET), File.join(app, 'target.mk'))
      File.write(File.join(app, 'flags.mk'), "CC_OPT += #{PeerBench.flags.join(' ')}\n")
      SOURCES.each do |path|
        FileUtils.mkdir_p(File.join(app, 'root', File.dirname(path)))
        FileUtils.cp_r(File.join(root, path), File.join(app, 'root', path))
      end
      File.write(File.join(inputs, 'repo/run', "#{PROGRAM}.run"), run_script(arguments: arguments))
      fetched.sources.select { |source| GenodeFetch::PORT.match?(source.fetch('id')) }.each do |source|
        port = File.join(inputs, 'ports', source.fetch('id').delete_prefix('genode-port-'))
        FileUtils.mkdir_p(port)
        FileUtils.copy_file(fetched.fetched_file(source.fetch('id')), File.join(port, source.fetch('filename')))
      end
      inputs
    end
    private_class_method :stage_inputs

    # The tool archives the engine extracts at the container's root, as [path, prefix]:
    # the tool chain's archive and each tool package's data archive, each checked whole
    # (check_archive) after xz decompresses it on the host into a file that is then
    # removed. Nothing of them runs on the host.
    def stage_archives(runner:, fetched:, directory:)
      packages = fetched.sources.select { |source| source.fetch('id').start_with?(GenodeFetch::TOOL) }.map do |source|
        path = File.join(directory, "#{source.fetch('id')}.tar.xz")
        File.binwrite(path, data_archive(File.binread(fetched.fetched_file(source.fetch('id')))))
        [path, PACKAGE_PREFIX]
      end
      [[fetched.fetched_file('genode-toolchain'), TOOLCHAIN_PREFIX], *packages].each do |path, prefix|
        unpacked = File.join(directory, 'unpacked.tar')
        runner.run(['xz', '--decompress', '--stdout', path], name: 'genode-build-xz', deadline: 1800,
                                                             output_limit: UNPACKED_BYTES, stdout: unpacked)
        File.open(unpacked, 'rb') { |io| check_archive(io, prefix: prefix, label: "#{LABEL}'s #{File.basename(path)}") }
        FileUtils.rm_f(unpacked)
      end
    end
    private_class_method :stage_archives

    def publish(root:, out:, record:)
      destination = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      FileUtils.rm_f(Dir.glob(File.join(destination, '*')))
      %w[image.elf config].each { |name| FileUtils.copy_file(File.join(out, name), File.join(destination, name)) }
      File.write(File.join(destination, 'record.json'), JSON.pretty_generate(record) + "\n")
      File.join(destination, 'image.elf')
    end
    private_class_method :publish
  end
end
