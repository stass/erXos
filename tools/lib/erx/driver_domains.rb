# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'block_device'

module Erx
  # The drivers' domains on QEMU virt: what ends a domain that holds a device, and how it
  # comes back. The storage domain holds the block unit and runs the block driver and
  # littlefs's /data (docs/design-stopgap.md, "littlefs in the storage domain"); a failure
  # of littlefs ends that domain, whose restart gives it the device again and mounts /data
  # afresh.
  #
  # The littlefs restart boots the block device suite's test image (block_device.rb, which
  # builds it with the test module erx_blk_check) on a fresh medium and starts the module's
  # `lfs_restart` entry in the system domain. Its lines, in this order and no others
  # starting with "blk: ", each perhaps opened by the command shell's prompt:
  #
  #   blk: lfs wrote 10000 bytes    at the storage domain's node, /data/restarted written
  #                                 with DATA_BYTES bytes and closed
  #   blk: lfs worker found         the node's littlefs worker, the process the erx_lfs
  #                                 owner links to besides its supervisor, is found,
  #                                 and is killed a moment after this line leaves the node
  #   blk: storage domain ended     the system domain sees storage@erxos go down
  #   blk: storage domain back      the domain's next incarnation runs erx_storage
  #   blk: lfs read back 10000 bytes
  #                                 /data/restarted, read at the new incarnation, holds
  #                                 what was written: the same volume, mounted afresh
  #   blk: done
  #
  # A domain that stays up prints "blk: storage domain did not end" after a minute, one
  # that does not come back "blk: storage domain not back", and a step that fails at the
  # storage node "blk: no driver: REASON" or its own "failed" line.
  module DriverDomains
    RESTART_ARGUMENTS = ['-pa', BlockDevice::GUEST_PATH, '-run', BlockDevice::GUEST_MODULE, 'lfs_restart'].freeze
    # Seconds the guest has, after its banner, to print "blk: done": the storage domain
    # boots twice, and the kill waits up to a minute for the first to end.
    RESTART_SECONDS = 300

    module_function

    def restart_expected_lines
      bytes = BlockDevice::DATA_BYTES
      ["blk: lfs wrote #{bytes} bytes", 'blk: lfs worker found', 'blk: storage domain ended',
       'blk: storage domain back', "blk: lfs read back #{bytes} bytes", 'blk: done']
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @block = BlockDevice::Run.new(root: root, runner: runner, compiler: compiler, linker: linker)
      end

      # Runs the littlefs restart under each accelerator at one CPU. Returns
      # { "<accelerator>-1cpu" => 'passed' }; any disagreement raises.
      def call(accels:, jobs: 4, build: true)
        image = @block.test_image_for(accels: accels, jobs: jobs, build: build)
        accels.to_h do |accel|
          ["#{accel}-1cpu", @block.boot_fresh_medium(accel, image, arguments: RESTART_ARGUMENTS,
                                                                   expected: DriverDomains.restart_expected_lines,
                                                                   seconds: RESTART_SECONDS)]
        end
      end
    end
  end
end
