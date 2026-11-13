# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'

module Erx
  # The chokepoint "only the block driver's one write path issues writes"
  # (docs/design-storage.md, "The block driver", and invariant U4), held by construction.
  # A block device reads or writes the medium only for a request a driver posts with
  # erx_device:post/4, and erx_blk_write is the one module that posts: it builds every
  # request it posts, header and request type included, from its own functions, and only
  # its write/6 builds a request whose type writes. Whatever another module builds, it has
  # no way to hand it to the device. The rule is therefore that no Erlang source but
  # erx_blk_write calls erx_device:post/4. The network stack's virtio transport,
  # erx_virtio_net, is the other site: a network device's requests carry frames, and the
  # transport is the one module that posts them. The virtio-gpu display driver,
  # erx_virtio_gpu, is the third: a display device only reads the screen image and is
  # handed no medium to write, and the driver's process is the one module that posts its
  # requests, every one built by its pure core (docs/design-display.md, "The display device").
  # An SD host controller acts when its command register is written, which only
  # erx_device:command/2 does, so the same rule holds command/2, with erx_blk_write its one
  # site: the SD write path builds every command word, and only its write function builds
  # CMD24 or CMD25.
  #
  # The check reads the Erlang sources DeviceCallers reads, with comments removed and
  # strings kept, over the whole text, so a call split across lines is seen too. It
  # refuses an issuing call named as a call target outside its sites: erx_device:post or
  # erx_device:command, as a remote call or a fun; the atom erx_device with post or command
  # as the next argument, as an apply passes them; and any import from erx_device, which
  # would let a module call either by its bare name.
  # DeviceCallers already keeps erx_device's name inside erx_device itself and the driver
  # applications; within those few modules, this check catches a slip, not a module that
  # holds the module name in a variable, which their review must.
  module DevicePosters
    WRITE_PATH = 'erlang/apps/erx_blk/src/erx_blk_write.erl'
    SITES = [WRITE_PATH, 'erlang/apps/erx_net/erxos/erx_virtio_net.erl',
             'erlang/apps/erx_fb/src/erx_virtio_gpu.erl'].freeze
    # Each issuing call and the modules that may name it.
    ISSUERS = { 'post' => SITES, 'command' => [WRITE_PATH].freeze }.freeze
    ATOM = ->(name) { "(?<![A-Za-z0-9_@'])(?:#{name}|'#{name}')(?![A-Za-z0-9_@'])" }
    NAMED = ISSUERS.keys.to_h do |call|
      [call, /#{ATOM.call('erx_device')} \s* (?: : | , ) \s* #{ATOM.call(call)}/x]
    end.freeze
    IMPORTED = /-\s*import\s*\(\s*#{ATOM.call('erx_device')}/x

    Violation = Data.define(:path, :line, :call) do
      def to_s
        "chokepoint device-posters: #{path}:#{line}: only #{ISSUERS.fetch(call).join(', ')} may call erx_device:#{call}"
      end
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text. An import names every
    # issuing call by its bare name, so it is post's violation outside post's sites and
    # command's outside command's, reported once.
    def violations(files)
      files.flat_map do |path, text|
        next [] unless covers?(path)

        code = DeviceCallers.code(text)
        ISSUERS.flat_map do |call, sites|
          next [] if sites.include?(path)

          lines(code, NAMED.fetch(call)).union(lines(code, IMPORTED))
                                        .map { |line| Violation.new(path: path, line: line, call: call) }
        end
      end.uniq { |violation| [violation.path, violation.line] }
    end

    def lines(code, pattern)
      code.to_enum(:scan, pattern).map { code[0, Regexp.last_match.begin(0)].count("\n") + 1 }
    end
  end
end
