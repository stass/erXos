# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rubygems/package'
require_relative 'dependencies'
require_relative 'error'

module Erx
  # What the container builds of the comparison guests share (docs/design-bench.md, "L4Re's
  # guest" and "Genode's guest"): a guest's build runs its own build system inside a
  # container the oracle's confinement flags create, as the non-root user USER, on an
  # engine reached by its local UNIX socket, and only an archive of its outputs comes back.
  # This module owns the docker command of a step, the check of the created container, the
  # reader of the exported archive and the container's removal; L4ReBuild and GenodeBuild
  # each own their plan, inputs and build record.
  module GuestBuild
    USER = '1000:1000'

    # One docker command of a build: its run name, arguments, deadline, the most bytes it
    # may write (Runner's output_limit), the path its standard output goes to and the path
    # its standard input comes from.
    Step = Data.define(:name, :argv, :deadline, :limit, :stdout, :stdin) do
      def initialize(name:, argv:, deadline: 600, limit: nil, stdout: nil, stdin: nil) = super
    end

    module_function

    def run(runner, step)
      runner.run(step.argv, name: step.name, deadline: step.deadline, env: Dependencies::DOCKER_ENVIRONMENT,
                            output_limit: step.limit, stdout: step.stdout, stdin: step.stdin)
    end

    # Refuses the created container unless the engine holds it as created: offline, with
    # an init, no capability, privilege or mount, as the non-root user. An engine or
    # daemon setting that dropped a flag would otherwise go unseen. label names the build.
    def check_container(value, label:)
      host = value.is_a?(Hash) ? value['HostConfig'] : nil
      config = value.is_a?(Hash) ? value['Config'] : nil
      confined = host.is_a?(Hash) && config.is_a?(Hash) && host['NetworkMode'] == 'none' &&
                 host['Init'] == true && host['Privileged'] == false && host['CapDrop'] == ['ALL'] &&
                 [nil, []].include?(host['CapAdd']) && host['SecurityOpt'] == ['no-new-privileges'] &&
                 [nil, []].include?(host['Binds']) && value['Mounts'] == [] && config['User'] == USER
      raise Error, "the engine does not hold #{label} container as created (offline, unprivileged, unmounted)" unless confined
    end

    # The text output name of out, refused unless it is printable ASCII lines: the
    # container wrote it, and the record and the terminal show it.
    def text(out, name, label:)
      bytes = File.binread(File.join(out, name))
      raise Error, "#{label} exported #{name} with bytes other than printable ASCII lines" unless
        bytes.match?(/\A[\t\n -~]*\z/n)

      bytes.force_encoding(Encoding::US_ASCII)
    end

    # Writes outputs (name => most bytes) from archive, the tar docker cp streamed of
    # /tmp/out, into the new directory out, once the whole archive is read and checked.
    def unpack(archive:, out:, outputs:, label:)
      files = read_outputs(archive, outputs: outputs, label: label)
      Dir.mkdir(out, 0o700)
      files.each { |name, bytes| File.binwrite(File.join(out, name), bytes) }
    end

    # The outputs archive holds, as name => bytes. The container wrote it, so it is refused
    # unless it holds the directory out and exactly outputs in it, each a regular file
    # within its bound with all its bytes present, and ends in tar's zero block: no link,
    # device, extended header, other name or truncated archive is accepted.
    def read_outputs(archive, outputs:, label:)
      File.open(archive, 'rb') do |io|
        files = Gem::Package::TarReader.new(io).filter_map do |entry|
          path = entry.full_name
          next if entry.directory? && path.delete_suffix('/') == 'out'

          name = path.delete_prefix('out/')
          bound = entry.header.typeflag == '0' && path == "out/#{name}" && outputs[name]
          raise Error, "#{label} exported an entry other than out/ and its regular files within their bounds" unless
            bound && entry.header.size <= bound

          bytes = entry.read.to_s
          raise Error, "#{label} exported a truncated archive" unless bytes.bytesize == entry.header.size

          [name, bytes]
        end
        raise Error, "#{label} exported an archive without tar's end" unless ended?(io)
        raise Error, "#{label} exported #{files.size} outputs, not once each of #{outputs.keys.join(', ')}" unless
          files.map(&:first).sort == outputs.keys.sort

        files.to_h
      end
    rescue Gem::Package::Error
      raise Error, "#{label} exported an archive that is not a tar"
    end
    private_class_method :read_outputs

    # Whether the reader stopped at tar's zero block, not at the end of a cut archive.
    def ended?(io) = io.pos >= 512 && io.pread(512, io.pos - 512) == "\0".b * 512
    private_class_method :ended?

    # Removes the build's container; raising is false while another failure propagates,
    # which a failed removal must not replace.
    def remove(runner:, endpoint:, name:, raising:)
      runner.run(['docker', '--host', endpoint, 'rm', '--force', name], name: 'guest-build-remove', deadline: 120,
                                                                         env: Dependencies::DOCKER_ENVIRONMENT)
    rescue Error
      raise if raising
    end
  end
end
