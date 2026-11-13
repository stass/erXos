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
  #
  # The check reads the Erlang sources DeviceCallers reads, with comments removed and
  # strings kept, over the whole text, so a call split across lines is seen too. It
  # refuses erx_device's post named as a call target: erx_device:post, as a remote call or
  # a fun; the atom erx_device with post as the next argument, as an apply passes them;
  # and any import from erx_device, which would let a module call post/4 by its bare name.
  # DeviceCallers already keeps erx_device's name inside erx_device itself and the driver
  # applications; within those few modules, this check catches a slip, not a module that
  # holds the module name in a variable, which their review must.
  module DevicePosters
    SITES = %w[erlang/apps/erx_blk/src/erx_blk_write.erl erlang/apps/erx_net/erxos/erx_virtio_net.erl
               erlang/apps/erx_fb/src/erx_virtio_gpu.erl].freeze
    ATOM = ->(name) { "(?<![A-Za-z0-9_@'])(?:#{name}|'#{name}')(?![A-Za-z0-9_@'])" }
    POSTED = /
      #{ATOM.call('erx_device')} \s* (?: : | , ) \s* #{ATOM.call('post')}
      | -\s*import\s*\(\s*#{ATOM.call('erx_device')}
    /x

    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint device-posters: #{path}:#{line}: only #{SITES.join(', ')} may call erx_device:post/4"
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] if !covers?(path) || SITES.include?(path)

        code = DeviceCallers.code(text)
        code.to_enum(:scan, POSTED).map do
          Violation.new(path: path, line: code[0, Regexp.last_match.begin(0)].count("\n") + 1)
        end
      end
    end
  end
end
