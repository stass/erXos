# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'rubygems/package'
require 'securerandom'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'error'
require_relative 'json_input'
require_relative 'l4re_bench'
require_relative 'l4re_fetch'
require_relative 'oracle_container'
require_relative 'output_directory'

module Erx
  # `tools/erx build l4re` (docs/design-bench.md, "L4Re's guest"): upstream Fiasco and
  # L4Re with ipcbench, built by their own make inside the oracle's arm64 toolchain image,
  # offline and as a non-root user with no capabilities, and bootstrap.elf brought back
  # with the build record L4ReBench::Build reads. Nothing fetched runs on the host: the
  # trees, the tool packages and the container script are copied into a container the
  # oracle's confinement flags create on an arm64 engine reached by its local UNIX
  # socket, and only an archive of the outputs is streamed out, bounded as it is
  # written, then unpacked only where it holds the expected regular files within their
  # bounds. The attached run's log is bounded too.
  #
  # The decisions are pure (kernel_defconfig, difference, plan, check_container, record);
  # unpack reads the exported archive whole before it writes anything, and build runs the
  # plan's docker commands and always removes the container it created and its work
  # directory.
  module L4ReBuild
    IMAGE_ID = 'oracle-toolchain-arm64'
    PLATFORM = 'linux/arm64'
    SCRIPT = 'bench/l4re/build.sh'
    KERNEL_DEFCONFIG = 'config/fiasco/kernel.defconfig'
    # What differs between the guest's two builds (docs/design-bench.md, "L4Re's guest" and
    # "L4Re on the board"): L4Re's platform, its image target and the bootable file that
    # target leaves, L4Re's defconfig (from L4Re's own tree, or erXos's file of the board's
    # bootstrap) and where the outputs land. Fiasco is configured alike for both.
    Target = Data.define(:platform_type, :image_target, :bootable, :defconfig, :output)
    TARGETS = {
      'virt' => Target.new(platform_type: 'arm_virt', image_target: 'elfimage', bootable: 'bootstrap.elf',
                           defconfig: { tree: 'mk/defconfig/config.arm64-virt-v8a' }, output: 'build/l4re'),
      'raspi4b' => Target.new(platform_type: 'arm_gen', image_target: 'rawimage', bootable: 'bootstrap.raw',
                              defconfig: { erxos: 'config/fiasco/user-raspi4b.defconfig' }, output: 'build/l4re-raspi4b')
    }.freeze
    # Where each tree sits in the container: the manifest's layout under /tmp, so mk is
    # copied first and every package's parent, its pkg directory, exists when it lands.
    SOURCE_ROOT = '/tmp'
    # erXos's kernel defconfig names its LLVM programs; upstream Fiasco is built by the
    # image's gcc, so only these lines change (the record keeps what else differs).
    COMPILERS = { 'CONFIG_CC' => 'gcc', 'CONFIG_CXX' => 'g++', 'CONFIG_LD' => 'ld' }.freeze
    # What the container script leaves in /tmp/out beside the target's bootable file, each
    # with the most bytes it may hold.
    OUTPUTS = { 'globalconfig.out' => 1 << 20, 'l4re.kconfig' => 1 << 20, 'compiler' => 4096 }.freeze
    BOOTABLE_BYTES = 64 << 20
    DEADLINE = 4 * 3600
    # The most bytes the attached run may log, and the archive of the outputs may hold:
    # their bounds with room for the archive's headers.
    RUN_LOG_BYTES = 64 << 20
    ARCHIVE_BYTES = OUTPUTS.values.sum + BOOTABLE_BYTES + (64 << 10)
    USER = '1000:1000'
    # The script's whole environment: the container's entry starts it under env -i.
    ENVIRONMENT = ['HOME=/tmp', 'PATH=/usr/local/bin:/usr/bin:/bin', 'LANG=C'].freeze

    # One docker command of a build: its run name, arguments, deadline, the most bytes it
    # may write (Runner's output_limit) and the path its standard output goes to.
    Step = Data.define(:name, :argv, :deadline, :limit, :stdout) do
      def initialize(name:, argv:, deadline: 600, limit: nil, stdout: nil) = super
    end

    module_function

    # Every file target's build leaves in /tmp/out, with the most bytes it may hold.
    def outputs_of(target) = OUTPUTS.merge(target.bootable => BOOTABLE_BYTES)

    # erXos's kernel defconfig with gcc's programs in place of its compiler lines; each
    # line must be present exactly once, so a renamed line cannot keep clang silently.
    def kernel_defconfig(text)
      COMPILERS.reduce(text) do |config, (name, program)|
        pattern = /^#{name}="[^"\n]*"$/
        raise Error, "#{KERNEL_DEFCONFIG} sets #{name} #{config.scan(pattern).size} times, not once" unless
          config.scan(pattern).size == 1

        config.sub(pattern, "#{name}=\"#{program}\"")
      end
    end

    # The settings of defconfig that the resolved configuration does not keep, as
    # "CONFIG_X: defconfig VALUE, resolved VALUE" lines; "n" stands for an unset option.
    def difference(defconfig:, resolved:)
      wanted = settings(defconfig)
      held = settings(resolved)
      wanted.filter_map do |name, value|
        "#{name}: defconfig #{value}, resolved #{held.fetch(name, 'n')}" unless held.fetch(name, 'n') == value
      end
    end

    def settings(text)
      text.each_line.filter_map do |line|
        case line.chomp
        when /\A(CONFIG_\w+)=(.*)\z/ then [Regexp.last_match(1), Regexp.last_match(2)]
        when /\A# (CONFIG_\w+) is not set\z/ then [Regexp.last_match(1), 'n']
        end
      end.to_h
    end
    private_class_method :settings

    # The docker commands of one build on the engine at endpoint: create the container,
    # inspect it, copy the inputs and each tree in, run the script attached, and stream
    # /tmp/out to archive as a tar. trees maps each LAYOUT path to its fetched tree on
    # the host.
    def plan(endpoint:, name:, image:, inputs:, trees:, archive:, jobs:, target: TARGETS.fetch('virt'))
      docker = ['docker', '--host', endpoint]
      memory = "#{2 * jobs}g"
      copies = [[inputs, '/tmp/inputs'], *trees.sort_by { |path, _| path.count('/') }
                                               .map { |path, tree| [tree, File.join(SOURCE_ROOT, path)] }]
      {
        create: Step.new(name: 'l4re-build-create', argv: [
          *docker, 'create', '--pull', 'never', '--platform', PLATFORM, '--name', name,
          *OracleContainer::CONFINEMENT, '--user', USER, '--workdir', '/tmp', '--pids-limit', '4096',
          '--cpus', jobs.to_s, '--memory', memory, '--memory-swap', memory,
          '--entrypoint', '/usr/bin/env', image, '-i', *ENVIRONMENT,
          '/usr/bin/timeout', '-k', '10', DEADLINE.to_s, '/bin/sh', '/tmp/inputs/build.sh', jobs.to_s,
          target.platform_type, target.image_target, File.extname(target.bootable).delete_prefix('.')
        ]),
        inspect: Step.new(name: 'l4re-build-inspect', argv: [*docker, 'inspect', '--type', 'container', name,
                                                             '--format', '{{json .}}'], limit: 1 << 20),
        copies: copies.map { |from, to| Step.new(name: 'l4re-build-copy', argv: [*docker, 'cp', from, "#{name}:#{to}"]) },
        start: Step.new(name: 'l4re-build-run', argv: [*docker, 'start', '--attach', name],
                        deadline: DEADLINE + 60, limit: RUN_LOG_BYTES),
        export: Step.new(name: 'l4re-build-export', argv: [*docker, 'cp', "#{name}:/tmp/out", '-'],
                         limit: ARCHIVE_BYTES, stdout: archive)
      }
    end

    # Refuses the created container unless the engine holds it as plan created it:
    # offline, with an init, no capability, privilege or mount, as the non-root user. An
    # engine or daemon setting that dropped a flag would otherwise go unseen.
    def check_container(value)
      host = value.is_a?(Hash) ? value['HostConfig'] : nil
      config = value.is_a?(Hash) ? value['Config'] : nil
      confined = host.is_a?(Hash) && config.is_a?(Hash) && host['NetworkMode'] == 'none' &&
                 host['Init'] == true && host['Privileged'] == false && host['CapDrop'] == ['ALL'] &&
                 [nil, []].include?(host['CapAdd']) && host['SecurityOpt'] == ['no-new-privileges'] &&
                 [nil, []].include?(host['Binds']) && value['Mounts'] == [] && config['User'] == USER
      raise Error, "the engine does not hold L4Re's build container as created (offline, unprivileged, unmounted)" unless confined
    end

    # The build record of the exported outputs in out: the pins of every source and
    # package, the image, the compiler, the resolved configurations and the difference of
    # Fiasco's and L4Re's resolved configurations from their defconfigs, and the bootable
    # file's SHA-256, which names the image it describes. A resolved L4Re configuration of
    # another platform than target's is refused, since Kconfig drops what it does not know.
    def record(sources:, image:, out:, defconfig:, target: TARGETS.fetch('virt'), l4re_defconfig: '')
      resolved = text(out, 'globalconfig.out')
      l4re = text(out, 'l4re.kconfig')
      raise Error, "L4Re's build resolved another platform than #{target.platform_type}" unless
        l4re.match?(/^CONFIG_PLATFORM_TYPE_#{target.platform_type}=y$/)
      {
        'sources' => sources.to_h { |source| [source.fetch('id'), source.fetch('kind') == 'git' ? source.fetch('commit') : source.fetch('sha256')] },
        'image' => image, 'platform' => PLATFORM, 'l4re_platform' => target.platform_type,
        'compiler' => text(out, 'compiler').lines.first.to_s.strip,
        'compiler_flags' => "Fiasco's and L4Re's own for this configuration",
        'fiasco_config_sha256' => Digest::SHA256.hexdigest(resolved),
        'fiasco_config_difference' => difference(defconfig: defconfig, resolved: resolved),
        'l4re_config_sha256' => Digest::SHA256.hexdigest(l4re),
        'l4re_config_difference' => difference(defconfig: l4re_defconfig, resolved: l4re),
        'bootable' => target.bootable,
        'bootstrap_sha256' => Digest::SHA256.file(File.join(out, target.bootable)).hexdigest
      }
    end

    # The text output name of out, refused unless it is printable ASCII lines: the
    # container wrote it, and the record and the terminal show it.
    def text(out, name)
      bytes = File.binread(File.join(out, name))
      raise Error, "L4Re's build exported #{name} with bytes other than printable ASCII lines" unless
        bytes.match?(/\A[\t\n -~]*\z/n)

      bytes.force_encoding(Encoding::US_ASCII)
    end
    private_class_method :text

    # Writes target's outputs (outputs_of) from archive, the tar docker cp streamed of
    # /tmp/out, into the new directory out, once the whole archive is read and checked.
    def unpack(archive:, out:, target: TARGETS.fetch('virt'))
      files = outputs(archive, outputs_of(target))
      Dir.mkdir(out, 0o700)
      files.each { |name, bytes| File.binwrite(File.join(out, name), bytes) }
    end

    # The outputs archive holds, as name => bytes. The container wrote it, so it is refused
    # unless it holds the directory out and exactly expected in it, each a regular file
    # within its bound with all its bytes present, and ends in tar's zero block: no link,
    # device, extended header, other name or truncated archive is accepted.
    def outputs(archive, expected)
      File.open(archive, 'rb') do |io|
        files = Gem::Package::TarReader.new(io).filter_map do |entry|
          path = entry.full_name
          next if entry.directory? && path.delete_suffix('/') == 'out'

          name = path.delete_prefix('out/')
          bound = entry.header.typeflag == '0' && path == "out/#{name}" && expected[name]
          raise Error, "L4Re's build exported an entry other than out/ and its regular files within their bounds" unless
            bound && entry.header.size <= bound

          bytes = entry.read.to_s
          raise Error, "L4Re's build exported a truncated archive" unless bytes.bytesize == entry.header.size

          [name, bytes]
        end
        raise Error, "L4Re's build exported an archive without tar's end" unless ended?(io)
        raise Error, "L4Re's build exported #{files.size} outputs, not once each of #{expected.keys.join(', ')}" unless
          files.map(&:first).sort == expected.keys.sort

        files.to_h
      end
    rescue Gem::Package::Error
      raise Error, "L4Re's build exported an archive that is not a tar"
    end
    private_class_method :outputs

    # Whether the reader stopped at tar's zero block, not at the end of a cut archive.
    def ended?(io) = io.pos >= 512 && io.pread(512, io.pos - 512) == "\0".b * 512
    private_class_method :ended?

    # Builds L4Re's guest for target on the engine of the docker context, leaving its
    # bootable file, globalconfig.out and the build record in target's output directory.
    # Returns the bootable file's path.
    def build(root:, runner:, context:, jobs:, target: TARGETS.fetch('virt'))
      raise Error, 'L4Re build jobs must be 1 to 64' unless jobs.is_a?(Integer) && jobs.between?(1, 64)

      dependencies = Dependencies.new(root: root, runner: runner, docker_context: context)
      endpoint = dependencies.local_docker_connection.fetch('endpoint')
      fetched = L4ReFetch.lock(root: root, runner: runner)
      image = dependencies.image_for(IMAGE_ID).fetch('reference')
      work = OutputDirectory.prepare(root: root, path: File.join(root, 'build/l4re-work'))
      directory = Dir.mktmpdir('build-', work)
      inputs = stage_inputs(root: root, fetched: fetched, directory: directory, target: target)
      defconfig = File.read(File.join(inputs, 'kernel.defconfig'))
      name = "erx-l4re-build-#{SecureRandom.hex(8)}"
      trees = L4ReFetch::LAYOUT.to_h { |id, path| [path, fetched.fetched_tree(id)] }
      archive = File.join(directory, 'out.tar')
      steps = plan(endpoint: endpoint, name: name, image: image, inputs: inputs, trees: trees, archive: archive, jobs: jobs, target: target)
      run = lambda do |step|
        runner.run(step.argv, name: step.name, deadline: step.deadline, env: Dependencies::DOCKER_ENVIRONMENT,
                              output_limit: step.limit, stdout: step.stdout)
      end
      begin
        run.call(steps.fetch(:create))
        check_container(JsonInput.parse(File.binread(run.call(steps.fetch(:inspect)).fetch('log')),
                                        max_bytes: 1 << 20, label: "L4Re's build container"))
        steps.fetch(:copies).each(&run)
        run.call(steps.fetch(:start))
        run.call(steps.fetch(:export))
      ensure
        # Also on an interrupt; a failed removal raises only when nothing else propagates.
        remove(runner: runner, endpoint: endpoint, name: name, raising: $!.nil?)
      end
      out = File.join(directory, 'out')
      unpack(archive: archive, out: out, target: target)
      publish(root: root, out: out, target: target,
              record: record(sources: fetched.sources, image: image, out: out, defconfig: defconfig, target: target,
                             l4re_defconfig: File.read(File.join(inputs, 'l4re.defconfig'))))
    ensure
      FileUtils.rm_rf(directory) if directory
    end

    # Removes the build's container; raising is false while another failure propagates,
    # which a failed removal must not replace.
    def remove(runner:, endpoint:, name:, raising:)
      runner.run(['docker', '--host', endpoint, 'rm', '--force', name], name: 'l4re-build-remove', deadline: 120,
                                                                         env: Dependencies::DOCKER_ENVIRONMENT)
    rescue Error
      raise if raising
    end
    private_class_method :remove

    # The container's /tmp/inputs: the script, Fiasco's and target's L4Re defconfigs and the
    # tool packages.
    def stage_inputs(root:, fetched:, directory:, target:)
      inputs = File.join(directory, 'inputs')
      FileUtils.mkdir_p(File.join(inputs, 'packages'))
      FileUtils.copy_file(File.join(root, SCRIPT), File.join(inputs, 'build.sh'))
      File.write(File.join(inputs, 'kernel.defconfig'), kernel_defconfig(File.read(File.join(root, KERNEL_DEFCONFIG))))
      l4re = target.defconfig
      FileUtils.copy_file(l4re.key?(:tree) ? File.join(fetched.fetched_tree('l4re-mk'), l4re.fetch(:tree)) : File.join(root, l4re.fetch(:erxos)),
                          File.join(inputs, 'l4re.defconfig'))
      L4ReFetch.packages(fetched).each { |package| FileUtils.copy_file(package, File.join(inputs, 'packages', File.basename(package))) }
      inputs
    end
    private_class_method :stage_inputs

    def publish(root:, out:, record:, target:)
      destination = OutputDirectory.prepare(root: root, path: File.join(root, target.output))
      build = L4ReBench::Build.new(directory: destination, bootable: target.bootable)
      raise Error, "L4Re's build record holds text other than printable ASCII" unless L4ReBench.printable?(record)

      FileUtils.rm_f([build.bootstrap, build.record_path])
      FileUtils.copy_file(File.join(out, 'globalconfig.out'), File.join(destination, 'globalconfig.out'))
      FileUtils.copy_file(File.join(out, target.bootable), build.bootstrap)
      File.write(build.record_path, JSON.pretty_generate(record) + "\n")
      build.bootstrap
    end
    private_class_method :publish
  end
end
