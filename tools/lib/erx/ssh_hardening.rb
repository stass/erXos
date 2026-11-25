# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # What every ssh the host tools run carries, whatever the user's ~/.ssh/config says: no
  # agent, X11 or port forwarding, so whoever answers at the destination reaches nothing
  # of the host's through the connection, and no shared connection to open or join. Each
  # call site adds only its own options (its host-key checking, its timeouts).
  module SshHardening
    OPTIONS = %w[-a -x -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none].freeze
  end
end
