# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'stringio'
require 'tmpdir'
require_relative 'checked_tar'
require_relative 'dependencies'
require_relative 'error'
require_relative 'genode_fetch'
require_relative 'guest_build'
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
  # and the Debian tool packages are untrusted data that nothing on the host runs. The
  # host reads the archives the engine extracts at the container's root only to check
  # them and write them afresh (CheckedTar), so the engine extracts exactly what was
  # checked. Genode's run tool takes a Tcl script, which run_script writes from erXos's
  # own values into the container's inputs; no Tcl file is in erXos's tree.
  #
  # The decisions are pure (run_script, data_archive, plan, record); build stages the
  # inputs and the checked archives, runs the plan's docker commands (GuestBuild.execute)
  # and always removes the container and its work directory.
  module GenodeBuild
    LABEL = "Genode's build"
    TAG = 'genode-build'
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
    OUTPUTS = { 'image.elf' => 64 << 20, 'compiler' => 4096 }.freeze
    DEADLINE = 4 * 3600
    ARCHIVE_BYTES = OUTPUTS.values.sum + (64 << 10)
    # The most bytes a tool archive may decompress to on the host for its check.
    UNPACKED_BYTES = 8 << 30
    # Where each archive the engine extracts at the container's root may write: Debian's
    # packages under usr/, the tool chain under its own install directory.
    PACKAGE_PREFIX = 'usr/'
    TOOLCHAIN_PREFIX = 'usr/local/genode/tool/'
    # An ar member's header: name, modification time, owner, group, mode, size, magic.
    AR_MEMBER = 'A16 A12 A6 A6 A8 A10 a2'

    module_function

    # Genode's run script for erx_peer_bench given arguments: the depot's archives the
    # probe of Genode's tools built, the component built from erXos's target description,
    # and init's configuration in the notation Genode Foundations 26.05 documents ("The
    # init component"): the component's log on Genode's LOG, a /tmp in its memory, and an
    # affinity space of the boot's cpus CPUs in a row, all of it the component's, so that
    # the program's CPU n is the boot's ("Affinities" of the same chapter).
    def run_script(arguments:, cpus:)
      words = [PROGRAM, *arguments]
      raise Error, "#{LABEL}: program arguments must be words of letters, digits, '.', '_' or '-'" unless
        words.all? { |word| word.match?(/\A[A-Za-z0-9._-]+\z/) }
      raise Error, "#{LABEL}: a boot has 1 to 8 CPUs, not #{cpus.inspect}" unless cpus.is_a?(Integer) && cpus.between?(1, 8)

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
        + affinity-space | width: #{cpus} | height: 1
        + default | caps: 100
        + start timer | ram: 2M
          + provides | + service Timer
        + start #{PROGRAM} | ram: #{PROGRAM_RAM} | caps: 1000
          + affinity | xpos: 0 | ypos: 0 | width: #{cpus} | height: 1
          + config
            + vfs
              + dir dev | + log
              + dir tmp | + ram
            + libc | stdout: /dev/log | stderr: /dev/log
        #{words.map { |word| "    + arg | : #{word}" }.join("\n")}
        -
        }
        build_boot_image [build_artifacts]
      TCL
    end

    # The data archive of the Debian package bytes: its data.tar.xz member, the one the
    # engine extracts. Neither the control archive nor any script of the package is taken.
    def data_archive(bytes)
      package = StringIO.new(bytes)
      raise Error, "#{LABEL}: a tool package is not a Debian package (no ar header)" unless package.read(8) == "!<arch>\n"

      until package.eof?
        header = package.read(60).to_s
        name, *, size, magic = header.unpack(AR_MEMBER)
        data = package.read(size.to_i).to_s if size&.match?(/\A[0-9]{1,10}\z/)
        raise Error, "#{LABEL}: a tool package has a malformed ar member" unless
          header.bytesize == 60 && magic == "`\n" && data&.bytesize == size.to_i
        return data if name.delete_suffix('/') == 'data.tar.xz'

        package.read(size.to_i & 1)
      end
      raise Error, "#{LABEL}: a tool package has no data.tar.xz"
    end

    # The docker commands of one build on the engine at endpoint (GuestBuild.container_steps),
    # with the copies that feed the container: each checked tool archive (archives, host
    # paths) on standard input, extracted at its root, then the tree to /tmp/<directory>
    # with its two directories the build writes, and the inputs to /tmp/inputs.
    def plan(endpoint:, name:, image:, inputs:, tree:, directory:, writable:, archives:, archive:, jobs:, toolchain:)
      genode = "/tmp/#{directory}"
      environment = ['HOME=/tmp/home', "PATH=/usr/local/genode/tool/#{toolchain}/bin:/usr/local/bin:/usr/bin:/bin",
                     'LANG=C.UTF-8']
      copy = lambda do |from, to, **options|
        GuestBuild.copy_step(endpoint: endpoint, name: name, tag: TAG, from: from, to: to, **options)
      end
      GuestBuild.container_steps(endpoint: endpoint, name: name, tag: TAG, platform: PLATFORM, image: image,
                                 environment: environment, command: ['/bin/sh', '/tmp/inputs/build.sh', jobs.to_s, genode],
                                 jobs: jobs, deadline: DEADLINE, archive: archive, archive_bytes: ARCHIVE_BYTES)
                .merge(extracts: archives.map { |path| copy.call('-', '/', stdin: path, deadline: 1800) },
                       copies: [copy.call(tree, genode), copy.call("#{writable}/.", genode), copy.call(inputs, '/tmp/inputs')])
    end

    # The build record (docs/design-bench.md, "The record"): the pins of every source,
    # the image, the tool chain's compiler, the kernel and board, the program's arguments,
    # and the SHA-256 of the run script, which holds init's configuration the boot image
    # carries, and of the boot image; cpus is the boot's CPU count the script was written for.
    def record(sources:, image:, out:, arguments:, cpus:)
      {
        'sources' => sources.to_h { |source| [source.fetch('id'), source.fetch('kind') == 'git' ? source.fetch('commit') : source.fetch('sha256')] },
        'image' => image, 'platform' => PLATFORM, 'kernel' => KERNEL, 'board' => BOARD,
        'compiler' => GuestBuild.text(out, 'compiler', label: LABEL).lines.first.to_s.strip,
        'compiler_flags' => "Genode's own for this board, and erx_peer_bench's (bench/genode/target.mk)",
        'arguments' => arguments, 'cpus' => cpus,
        'run_script_sha256' => Digest::SHA256.hexdigest(run_script(arguments: arguments, cpus: cpus)),
        'image_sha256' => Digest::SHA256.file(File.join(out, 'image.elf')).hexdigest
      }
    end

    # Builds Genode's guest for a posix run on cpus CPUs on the engine of the docker
    # context, leaving image.elf and the build record in build/genode.
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
      inputs = stage_inputs(root: root, fetched: fetched, directory: directory, arguments: arguments, cpus: cpus)
      writable = File.join(directory, 'writable')
      %w[contrib depot].each do |name|
        FileUtils.mkdir_p(File.join(writable, name))
        File.chmod(0o1777, File.join(writable, name))
      end
      genode = fetched.sources.find { |source| source.fetch('id') == 'genode' }
      toolchain = fetched.sources.find { |source| source.fetch('id') == 'genode-toolchain' }.fetch('version')
      name = "erx-genode-build-#{SecureRandom.hex(8)}"
      archive = File.join(directory, 'out.tar')
      steps = plan(endpoint: endpoint, name: name, image: image, inputs: inputs, tree: fetched.fetched_tree('genode'),
                   directory: genode.fetch('directory'), writable: writable,
                   archives: stage_archives(runner: runner, fetched: fetched, directory: directory),
                   archive: archive, jobs: jobs, toolchain: toolchain)
      GuestBuild.execute(runner: runner, endpoint: endpoint, name: name, steps: steps,
                         feeds: steps.fetch(:extracts) + steps.fetch(:copies), label: LABEL)
      out = File.join(directory, 'out')
      GuestBuild.unpack(archive: archive, out: out, outputs: OUTPUTS, label: LABEL)
      publish(root: root, out: out, record: record(sources: fetched.sources, image: image, out: out, arguments: arguments,
                                                         cpus: cpus))
    ensure
      FileUtils.rm_rf(directory) if directory
    end

    # The container's /tmp/inputs: the script, each port's archive under ports/<port>/
    # with the name Genode's port tool asks for, and erXos's Genode repository: the
    # component's target description, its flags from their one source (PeerBench.flags),
    # the C files at their tree paths under its root/, and the run script.
    def stage_inputs(root:, fetched:, directory:, arguments:, cpus:)
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
      File.write(File.join(inputs, 'repo/run', "#{PROGRAM}.run"), run_script(arguments: arguments, cpus: cpus))
      fetched.sources.select { |source| GenodeFetch::PORT.match?(source.fetch('id')) }.each do |source|
        port = File.join(inputs, 'ports', source.fetch('id').delete_prefix('genode-port-'))
        FileUtils.mkdir_p(port)
        FileUtils.copy_file(fetched.fetched_file(source.fetch('id')), File.join(port, source.fetch('filename')))
      end
      inputs
    end
    private_class_method :stage_inputs

    # The tool archives the engine extracts at the container's root: the tool chain's
    # archive and each tool package's data archive, each decompressed by xz on the host,
    # read and written afresh under its prefix (CheckedTar), and its decompressed
    # original removed. Returns the checked archives' paths. Nothing of them runs on the
    # host.
    def stage_archives(runner:, fetched:, directory:)
      packages = fetched.sources.select { |source| source.fetch('id').start_with?(GenodeFetch::TOOL) }.map do |source|
        path = File.join(directory, "#{source.fetch('id')}.tar.xz")
        File.binwrite(path, data_archive(File.binread(fetched.fetched_file(source.fetch('id')))))
        [path, PACKAGE_PREFIX]
      end
      [[fetched.fetched_file('genode-toolchain'), TOOLCHAIN_PREFIX], *packages].map do |path, prefix|
        unpacked = File.join(directory, 'unpacked.tar')
        checked = File.join(directory, "#{File.basename(path, '.tar.xz')}.checked.tar")
        runner.run(['xz', '--decompress', '--stdout', path], name: 'genode-build-xz', deadline: 1800,
                                                             output_limit: UNPACKED_BYTES, stdout: unpacked)
        File.open(unpacked, 'rb') do |input|
          File.open(checked, 'wb') do |output|
            CheckedTar.rewrite(input, output, prefix: prefix, label: "#{LABEL}'s #{File.basename(path)}")
          end
        end
        FileUtils.rm_f(unpacked)
        checked
      end
    end
    private_class_method :stage_archives

    def publish(root:, out:, record:)
      destination = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      FileUtils.rm_f(Dir.glob(File.join(destination, '*')))
      FileUtils.copy_file(File.join(out, 'image.elf'), File.join(destination, 'image.elf'))
      File.write(File.join(destination, 'record.json'), JSON.pretty_generate(record) + "\n")
      File.join(destination, 'image.elf')
    end
    private_class_method :publish
  end
end
