# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    APP_TREES = 'docs/design-app-trees.md'
    SVC_CLIENT = 'erlang/apps/erx/src/erx_svc_client.erl'
    # A doc attribute and its string, which may name /svc in prose: the attribute at
    # a line's start, optionally parenthesised, and a plain, triple-quoted or sigil
    # string.
    DOC_STRING = /^-\s*(?:moduledoc|doc)\s*\(?\s*(?:~[bBsS]?)?(?:#{ErlangText::TRIPLE}|"(?:[^"\\]|\\.)*")/m

    # AT6: no system command waits on a service tree beyond the deadline it
    # gives, because erXos's applications read, write and open under /svc only
    # through erx_svc_client, which bounds each wait. The rule reads every module
    # of erlang/apps, the commands outside the command shell's application
    # among them, so its sites are an allow-list. It reads strings, since a path
    # is one: a string that is /svc or svc or begins /svc/ or svc/, or a quoted
    # atom that is /svc or begins /svc/, as <<"/svc/", Name/binary>> and
    # filename:join(["/", "svc", Name]) spell it. A doc string may name /svc in
    # prose.
    declare_group(
      rules: [
        Chokepoints::ErlangForbidden.new(
          name: 'svc-paths', rule: 'only erx_svc_client names /svc among the modules of erlang/apps; they reach a ' \
                                   "service's tree through erx_svc_client:read/4, command/3 and open/3",
          design: "#{APP_TREES}#invariants",
          scope: ['erlang/apps/**/*'], sites: [SVC_CLIENT],
          allowed: DOC_STRING,
          pattern: %r{"/?svc(?=[/"])|'/svc(?=[/'])},
          seed: { 'erlang/apps/erx_shell/src/erx_cmd_reboot.erl' =>
                    "w(L) -> file:write_file(<<\"/svc/machine/ctl\">>, L).\n",
                  'erlang/apps/erx_starter/src/seeded.erl' =>
                    "r(N) -> file:read_file(filename:join([\"/\", \"svc\", N, \"status\"])).\n" }
        )
      ]
    )
  end
end
