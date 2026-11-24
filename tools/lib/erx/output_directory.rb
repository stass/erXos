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
        raise Error, "output directory #{destination}: #{refusal(current, stat)}" unless stat.directory?
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

    # An empty directory at path under root, made afresh: the path is checked before
    # anything there is removed, so a link on it cannot send the removal elsewhere, and
    # root itself is never removed.
    def fresh(root:, path:, mode: 0o755)
      destination = check(root: root, path: path)
      raise Error, 'a fresh output directory must lie below its owner root' if destination == File.realpath(root)

      FileUtils.remove_entry(destination) if File.exist?(destination)
      prepare(root: root, path: destination, mode: mode)
    end

    # Why path cannot be on an output path, naming what holds its place. A link is named
    # as itself: File.realpath would name its target, or fail for a dangling one. Anything
    # else is named as the file system spells it, since one that ignores case takes a
    # file build/fiasco/NOTICES for build/fiasco/notices.
    def refusal(path, stat)
      return "#{path} is a symbolic link, which an output path may not cross" if stat.symlink?

      "#{File.realpath(path)} (type #{stat.ftype}) is not a directory"
    end
    private_class_method :refusal
  end
end
