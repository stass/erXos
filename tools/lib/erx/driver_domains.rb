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
  #
  # The corrupt volume boots the same image on a fresh medium whose /data a first boot
  # fills (the block device suite's data_write), and whose volume's superblock pair, both
  # copies of the root's metadata pair, the host then inverts. A mount never formats, so
  # each boot of the storage domain fails its mount with eintegrity and ends the domain,
  # and the domain service restarts it until its row's five restarts are spent. The second
  # boot starts the module's `lfs_corrupt` entry in the system domain, which prints
  #
  #   blk: storage domain ended 6 times
  #                                 its first boot and five restarts each ended, as the
  #                                 domain service's death records show
  #   blk: storage domain not restarted
  #                                 no incarnation is live, and none comes for a while
  #   blk: done
  #
  # and the harness then finds the data partition's bytes as the host left them. An
  # incarnation that runs erx_storage, which has mounted /data, prints "blk: storage
  # domain mounted /data after N ends" instead.
  module DriverDomains
    RESTART_ARGUMENTS = ['-pa', BlockDevice::GUEST_PATH, '-run', BlockDevice::GUEST_MODULE, 'lfs_restart'].freeze
    # Seconds the guest has, after its banner, to print "blk: done": the storage domain
    # boots twice, and the kill waits up to a minute for the first to end.
    RESTART_SECONDS = 300
    CORRUPT_ARGUMENTS = ['-pa', BlockDevice::GUEST_PATH, '-run', BlockDevice::GUEST_MODULE, 'lfs_corrupt'].freeze
    # Seconds the corrupt volume's guest has: six boots of the storage domain, each ending
    # at its mount, within the guest's five-minute watch.
    CORRUPT_SECONDS = 360

    module_function

    def restart_expected_lines
      bytes = BlockDevice::DATA_BYTES
      ["blk: lfs wrote #{bytes} bytes", 'blk: lfs worker found', 'blk: storage domain ended',
       'blk: storage domain back', "blk: lfs read back #{bytes} bytes", 'blk: done']
    end

    def corrupt_expected_lines = ['blk: storage domain ended 6 times', 'blk: storage domain not restarted', 'blk: done']

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @block = BlockDevice::Run.new(root: root, runner: runner, compiler: compiler, linker: linker)
      end

      # Runs the littlefs restart and the corrupt volume under each accelerator at one
      # CPU. Returns { "<accelerator>-1cpu" => 'passed' }; any disagreement raises.
      def call(accels:, jobs: 4, build: true)
        image = @block.test_image_for(accels: accels, jobs: jobs, build: build)
        accels.to_h do |accel|
          ["#{accel}-1cpu", @block.boot_fresh_medium(accel, image, arguments: RESTART_ARGUMENTS,
                                                                   expected: DriverDomains.restart_expected_lines,
                                                                   seconds: RESTART_SECONDS) &&
                                @block.boot_corrupt_medium(accel, image, arguments: CORRUPT_ARGUMENTS,
                                                                         expected: DriverDomains.corrupt_expected_lines,
                                                                         seconds: CORRUPT_SECONDS)]
        end
      end
    end
  end
end
