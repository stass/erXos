# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'error'
require_relative 'l4re_bench'
require_relative 'l4re_fetch'
require_relative 'output_directory'

module Erx
  # `tools/erx build l4re` (docs/design-bench.md, "L4Re's guest"): upstream Fiasco and
  # L4Re with ipcbench, built by their own make inside the oracle's arm64 toolchain image,
  # offline and as a non-root user with no capabilities, and bootstrap.elf brought back
  # with the build record L4ReBench::Build reads. Nothing fetched runs on the host: the
  # trees, the tool packages and the container script are copied into a created
  # container, which may live on an engine that emulates arm64, and only the outputs are
  # copied out, each checked as a regular file of bounded size before it is read.
  #
  # The decisions are pure (kernel_defconfig, difference, plan, record); build runs the
  # plan's docker commands in order and always removes the container it created.
  module L4ReBuild
    IMAGE_ID = 'oracle-toolchain-arm64'
    PLATFORM = 'linux/arm64'
    SCRIPT = 'bench/l4re/build.sh'
    KERNEL_DEFCONFIG = 'config/fiasco/kernel.defconfig'
    OUTPUT = 'build/l4re'
    # Where each tree sits in the container: the manifest's layout under /tmp, so mk is
    # copied first and every package's parent, its pkg directory, exists when it lands.
    SOURCE_ROOT = '/tmp'
    # erXos's kernel defconfig names its LLVM programs; upstream Fiasco is built by the
    # image's gcc, so only these lines change (the record keeps what else differs).
    COMPILERS = { 'CONFIG_CC' => 'gcc', 'CONFIG_CXX' => 'g++', 'CONFIG_LD' => 'ld' }.freeze
    # What the container script leaves in /tmp/out, each with the most bytes it may hold.
    OUTPUTS = { 'bootstrap.elf' => 64 << 20, 'globalconfig.out' => 1 << 20, 'l4re.kconfig' => 1 << 20,
                'compiler' => 4096 }.freeze
    DEADLINE = 4 * 3600

    module_function

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

    # The docker commands of one build, in order: create the container, copy the inputs
    # and each tree in, run the script attached, copy the outputs out. trees maps each
    # LAYOUT path to its fetched tree on the host.
    def plan(context:, name:, image:, inputs:, trees:, out:, jobs:)
      docker = ['docker', '--context', context]
      copies = [[inputs, '/tmp/inputs'], *trees.sort_by { |path, _| path.count('/') }
                                               .map { |path, tree| [tree, File.join(SOURCE_ROOT, path)] }]
      [[*docker, 'create', '--pull', 'never', '--platform', PLATFORM, '--name', name,
        '--network', 'none', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '--user', '1000:1000', '--env', 'HOME=/tmp', '--workdir', '/tmp', '--pids-limit', '4096',
        '--cpus', jobs.to_s, '--memory', (2 * jobs).to_s + 'g', '--log-driver', 'none',
        '--entrypoint', '/usr/bin/timeout', image, '-k', '10', DEADLINE.to_s,
        '/bin/sh', '/tmp/inputs/build.sh', jobs.to_s],
       *copies.map { |from, to| [*docker, 'cp', from, "#{name}:#{to}"] },
       [*docker, 'start', '--attach', name],
       [*docker, 'cp', "#{name}:/tmp/out", out]]
    end

    # The build record of the exported outputs in out: the pins of every source and
    # package, the image, the compiler, the resolved configurations and the difference of
    # Fiasco's from erXos's defconfig, and bootstrap.elf's SHA-256, which names the ELF it
    # describes.
    def record(sources:, image:, out:, defconfig:)
      resolved = text(out, 'globalconfig.out')
      {
        'sources' => sources.to_h { |source| [source.fetch('id'), source.fetch('kind') == 'git' ? source.fetch('commit') : source.fetch('sha256')] },
        'image' => image, 'platform' => PLATFORM,
        'compiler' => text(out, 'compiler').lines.first.to_s.strip,
        'compiler_flags' => "Fiasco's and L4Re's own for this configuration",
        'fiasco_config_sha256' => Digest::SHA256.hexdigest(resolved),
        'fiasco_config_difference' => difference(defconfig: defconfig, resolved: resolved),
        'l4re_config_sha256' => Digest::SHA256.file(File.join(out, 'l4re.kconfig')).hexdigest,
        'bootstrap_sha256' => Digest::SHA256.file(File.join(out, 'bootstrap.elf')).hexdigest
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

    # Refuses out unless it is a directory holding exactly OUTPUTS, each a regular file within its bound:
    # the container wrote it, so a link or an oversized file is never followed or read.
    def check_outputs(out)
      raise Error, "L4Re's build exported #{File.basename(out)} as other than a directory" unless File.lstat(out).directory?

      names = Dir.children(out).sort
      raise Error, "L4Re's build exported #{names.join(', ')}, not #{OUTPUTS.keys.sort.join(', ')}" unless names == OUTPUTS.keys.sort

      OUTPUTS.each do |name, maximum|
        stat = File.lstat(File.join(out, name))
        raise Error, "L4Re's build exported #{name} as other than a regular file of at most #{maximum} bytes" unless
          stat.file? && stat.size <= maximum
      end
    end

    # Builds L4Re's guest on the docker context, leaving bootstrap.elf, globalconfig.out
    # and the build record in build/l4re. Returns bootstrap.elf's path.
    def build(root:, runner:, context:, jobs:)
      raise Error, 'L4Re build jobs must be 1 to 64' unless jobs.is_a?(Integer) && jobs.between?(1, 64)
      raise Error, 'a Docker context name is letters, digits and _.+-' unless /\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,63}\z/.match?(context)

      fetched = L4ReFetch.lock(root: root, runner: runner)
      image = Dependencies.new(root: root, runner: runner).image_for(IMAGE_ID).fetch('reference')
      work = OutputDirectory.prepare(root: root, path: File.join(root, 'build/l4re-work'))
      directory = Dir.mktmpdir('build-', work)
      inputs = stage_inputs(root: root, fetched: fetched, directory: directory)
      defconfig = File.read(File.join(inputs, 'kernel.defconfig'))
      out = File.join(directory, 'out')
      name = "erx-l4re-build-#{SecureRandom.hex(8)}"
      trees = L4ReFetch::LAYOUT.to_h { |id, path| [path, fetched.fetched_tree(id)] }
      steps = plan(context: context, name: name, image: image, inputs: inputs, trees: trees, out: out, jobs: jobs)
      begin
        steps.each_with_index do |argv, index|
          runner.run(argv, name: "l4re-build-#{index}", deadline: argv.include?('start') ? DEADLINE + 60 : 600)
        end
      rescue StandardError
        remove(runner: runner, context: context, name: name, raising: false)
        raise
      end
      remove(runner: runner, context: context, name: name, raising: true)
      check_outputs(out)
      publish(root: root, out: out, record: record(sources: fetched.sources, image: image, out: out, defconfig: defconfig))
    end

    # Removes the build's container; raising is false while another failure propagates,
    # which a failed removal must not replace.
    def remove(runner:, context:, name:, raising:)
      runner.run(['docker', '--context', context, 'rm', '--force', name], name: 'l4re-build-remove', deadline: 120)
    rescue Error
      raise if raising
    end
    private_class_method :remove

    # The container's /tmp/inputs: the script, Fiasco's defconfig and the tool packages.
    def stage_inputs(root:, fetched:, directory:)
      inputs = File.join(directory, 'inputs')
      FileUtils.mkdir_p(File.join(inputs, 'packages'))
      FileUtils.copy_file(File.join(root, SCRIPT), File.join(inputs, 'build.sh'))
      File.write(File.join(inputs, 'kernel.defconfig'), kernel_defconfig(File.read(File.join(root, KERNEL_DEFCONFIG))))
      L4ReFetch.packages(fetched).each { |package| FileUtils.copy_file(package, File.join(inputs, 'packages', File.basename(package))) }
      inputs
    end
    private_class_method :stage_inputs

    def publish(root:, out:, record:)
      destination = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      build = L4ReBench::Build.new(directory: destination)
      raise Error, "L4Re's build record holds text other than printable ASCII" unless L4ReBench.printable?(record)

      FileUtils.rm_f([build.bootstrap, build.record_path])
      FileUtils.copy_file(File.join(out, 'globalconfig.out'), File.join(destination, 'globalconfig.out'))
      FileUtils.copy_file(File.join(out, 'bootstrap.elf'), build.bootstrap)
      File.write(build.record_path, JSON.pretty_generate(record) + "\n")
      build.bootstrap
    end
    private_class_method :publish
  end
end
