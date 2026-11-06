# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      rules: [
        Chokepoints::Elsewhere.new(
          name: 'ns-table-writer', rule: "only erx_ns's process writes the namespace's persistent term",
          design: 'docs/design-files.md#building-binding-and-mounting', check: 'NsWriters, in Checks',
          test: 'test/host/ns_writers_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'cwd-writer', rule: "only prim_file:set_cwd/1 calls the NIF that stores the working directory",
          design: 'docs/design-files.md#erlang-clients-prim_file-and-erx_file_remote', check: 'NsWriters, in Checks',
          test: 'test/host/ns_writers_test.rb'
        )
      ]
    )
  end
end
