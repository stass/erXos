# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'runner'

module Erx
  module BoundedFile
    module_function

    # Open without waiting on a FIFO, then check the opened object rather than
    # a pathname that can be replaced between stat and read. Consumers hash or
    # parse these same immutable bytes, never a second pathname read.
    def read(path, maximum:)
      unless path.is_a?(String) && path.bytesize.between?(1, 4096) && !path.b.include?("\0".b) &&
             maximum.is_a?(Integer) && maximum.between?(1, 512 * 1024 * 1024)
        raise Error, 'invalid bounded file read'
      end
      File.open(path, File::RDONLY | File::NONBLOCK) do |input|
        unless input.stat.file? && input.size <= maximum
          raise Error, "input is not a bounded regular file: #{path}"
        end
        input.binmode
        bytes = input.read(maximum + 1) || ''.b
        raise Error, "input exceeds its byte bound: #{path}" if bytes.bytesize > maximum
        bytes.freeze
      end
    rescue SystemCallError, IOError => error
      raise Error, "cannot read bounded file: #{error.message}"
    end
  end
end
