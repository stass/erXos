# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The wording rule of the stack proof's report (B8 of docs/design-stopgap.md):
# every allowance line names the C17 cores and leaves Fiasco's stack
# unproven, and no line names the kernel stack.
module StackProofClaim
  def assert_bounded_claim(lines)
    refute lines.any? { |line| line.match?(/kernel stack/i) }, 'a report line names the kernel stack'
    refute lines.any? { |line| line.match?(/stack: (?!unproven)/i) }, "a report line bounds a stack other than the cores'"
    summaries = lines.grep(/allowance/)
    refute_empty summaries
    summaries.each { |line| assert_match(/\AC17 cores: \d+ bytes of .*; Fiasco's stack: unproven /, line) }
  end
end
