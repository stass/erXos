# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # Ending a child that was spawned with `pgroup: true`: the child leads a process group of
  # its own, and the whole group is signalled so that no descendant outlives it. The
  # command runner and the boot benchmark both end their children this way.
  module ProcessGroup
    # The wait between looks at a child that is being ended.
    POLL_SECONDS = 0.05

    module_function

    # TERM to the group, a short grace for log writers to flush that ends as soon as the
    # group is empty, then KILL; the direct child is reaped. Descendants are killed by their
    # group id, never reaped here.
    def terminate(pid)
      signal('TERM', pid)
      stop_at = monotonic + 0.25
      emptied = loop do
        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          # The caller may already have reaped it.
        end
        break true if gone?(pid)
        break false if monotonic >= stop_at

        sleep(POLL_SECONDS)
      end
      # An emptied group names nothing any more, and its id may belong to another by now.
      signal('KILL', pid) unless emptied
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    # TERM or KILL to the whole group. A group with no live member is gone, whatever way the
    # host reports it: macOS reports a group whose members have all exited but are not yet
    # reaped as EPERM, not ESRCH. The group is our own child's; a member that changed user
    # could not be signalled in any case.
    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Whether no member can still flush or be signalled, by signal's reading of
    # the errors. Linux counts an unreaped child as a member, so the caller reaps first.
    def gone?(pid)
      Process.kill(0, -pid)
      false
    rescue Errno::ESRCH, Errno::EPERM
      true
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic
  end
end
