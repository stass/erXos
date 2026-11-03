# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'error'

module Erx
  # The caller supplies authority explicitly. Check the entire existing path
  # before creating anything; a linked child cannot redirect an output write.
  module OutputDirectory
    module_function

    def check(root:, path:)
      unless [root, path].all? { |value| value.is_a?(String) && !value.empty? && !value.b.include?("\0".b) }
        raise Error, 'invalid output directory request'
      end
      spelling = File.expand_path(root)
      owner = File.realpath(spelling)
      raise Error, 'output owner root is not a directory' unless File.directory?(owner)
      requested = File.expand_path(path, spelling)
      base = [spelling, owner].find { |candidate| requested == candidate || requested.start_with?(candidate + '/') }
      raise Error, 'output directory is outside its owner root' unless base
      relative = requested.delete_prefix(base).delete_prefix('/')
      destination = relative.empty? ? owner : File.join(owner, relative)
      current = owner
      relative.split('/').each do |component|
        current = File.join(current, component)
        begin
          stat = File.lstat(current)
        rescue Errno::ENOENT
          next
        end
        raise Error, 'output directory has a linked or non-directory ancestor' unless stat.directory?
      end
      destination
    rescue SystemCallError => error
      raise Error, "cannot prepare output directory: #{error.message}"
    end

    def prepare(root:, path:, mode: 0o755)
      raise Error, 'invalid output directory mode' unless mode.is_a?(Integer) && mode.between?(0, 0o777)
      destination = check(root: root, path: path)
      FileUtils.mkdir_p(destination, mode: mode)
      destination
    rescue SystemCallError => error
      raise Error, "cannot prepare output directory: #{error.message}"
    end
  end
end
