# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # Finding a host program on a PATH string for a build to run. Only the
  # absolute entries count: a relative or empty entry would name another
  # directory once a build changes into its own, so it is passed over, as
  # Setup#path_toolchain does.
  module HostPath
    module_function

    # The absolute directories of path, in order.
    def directories(path) = path.split(File::PATH_SEPARATOR).select { |directory| File.absolute_path?(directory) }

    # The first regular executable file named name in directories, or nil.
    def find_program(name, directories:)
      directories.map { |directory| File.join(directory, name) }
                 .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
    end
  end
end
