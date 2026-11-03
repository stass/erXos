# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # A directory of Ruby files, each declaring one thing named by its file
  # name: a chokepoint group, a fuzz target. Adding one is adding a file, so
  # parallel work never edits a shared list. Since the checks these feed are
  # security gates, a file that declares nothing or twice, a name that is
  # not plain, and a directory with no such file at all are all errors, not
  # a smaller gate. What must exist beyond that is each caller's own check.
  class DeclarationFiles
    NAME = /\A[a-z0-9_]+\z/

    def initialize(label)
      @label = label
      @loading = nil
      @declared = []
    end

    # Called by a declaration file while load_all loads it.
    def declare(value)
      raise Error, "#{@label}: a declaration outside a file being loaded" unless @loading

      @declared << value
    end

    # Loads each file named NAME + suffix in directory, in sorted order, so
    # the result does not depend on the file system's. Returns a frozen hash
    # from NAME to what the file declared, sorted by NAME.
    def load_all(directory, suffix: '.rb')
      files = Dir.glob("*#{suffix}", base: directory).sort
      raise Error, "#{@label}: no *#{suffix} file in #{directory}" if files.empty?

      files.to_h { |file| [plain_name(file, suffix), load_one(File.join(directory, file))] }.freeze
    end

    private

    def plain_name(file, suffix)
      name = file.delete_suffix(suffix)
      raise Error, "#{@label}: #{file} is not named in lower case, digits and underscores" unless NAME.match?(name)

      name
    end

    def load_one(path)
      @loading = path
      @declared = []
      load(path)
      raise Error, "#{@label}: #{path} declares nothing" if @declared.empty?
      raise Error, "#{@label}: #{path} declares #{@declared.size} times" unless @declared.size == 1

      @declared.first
    ensure
      @loading = nil
    end
  end
end
