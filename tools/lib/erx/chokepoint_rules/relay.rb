# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    RELAY_DESIGN = 'docs/design-shell.md#the-terminal-relays-protocol'
    # The registered name of the relay of the domain's line, which the
    # runtime's writers look for.
    TTY_OWNER = ErlangText::ATOM.call('erx_tty_owner')
    # A request for an open made for reading, `{open, Holder, read}`, with a
    # Holder of no tuple, list or call: what a module that reaches a relay by
    # its pid would build by hand. The tuple closes after `read`, so the
    # core's request, which carries the open the relay names in it as a
    # fourth element, is not a site; the relay refuses that shape from a
    # caller.
    OPEN_FOR_READING = /
        \{\s*#{ErlangText::ATOM.call('open')}\s*,\s*[^,{}()\[\]]+,\s*#{ErlangText::ATOM.call('read')}\s*\}
    /x

    # The terminal relay's three rules. Each catches a slip, not a
    # determined bypass: a module that makes the name, the function or the
    # request's mode at run time (list_to_atom/1, a computed apply/3, a
    # variable bound to `read`) passes, and what keeps a write-only open
    # from reading is the open's mode, which the relay checks on every read.
    # The readers' and the requests' rules blank strings, since a doc string
    # may name the function or the request; the name's rule keeps them,
    # since a string can become the atom, so a doc string names the relay's
    # name in words; the tests' modules lie outside otp/ and erlang/, so the
    # relay's own cases, which open for reading from the test process, are
    # not sites.
    declare_group(
      rules: [
        # Every reader of a job passes a scheduler pick between its ready
        # report and its read, which erx_cmd does, and the console belongs to
        # no job; a program's handler and a command domain's stream relay
        # open write-only. Refused outside erx_cmd and erx_console, in every
        # form ErlangText.calls refuses.
        Chokepoints::ErlangForbidden.new(
          name: 'relay-readers', rule: 'only erx_cmd and erx_console call erx_session_relay:open_reader, ' \
                                       'the one way to an open of the terminal made for reading',
          design: RELAY_DESIGN, strings: :blanked,
          pattern: ErlangText.calls(module_name: 'erx_session_relay', functions: %w[open_reader]),
          sites: %w[erlang/apps/erx_shell/src/erx_cmd.erl erlang/apps/erx/src/erx_console.erl],
          seed: { 'erlang/apps/erx_shell/src/seeded.erl' => "f(R, Job) -> erx_session_relay:open_reader(R, Job).\n" }
        ),
        # erx_session_relay's client functions make every request to a
        # relay, so no request, an open for reading included, is built by
        # hand (the rule below). The name's other holders: erx_output, the runtime's writers'
        # sender of tty_write and tty_drain, which every owner serves,
        # and the modules that hold the name in other domains, erx_console
        # in the system domain and erx_log_h's proxy in a domain with no
        # terminal (docs/design-runtime.md, "A process waits on its tty's
        # owner").
        Chokepoints::ErlangForbidden.new(
          name: 'relay-name', rule: 'only erx_session_relay, erx_output and the name\'s holders in other ' \
                                    'domains name erx_tty_owner, the terminal relay\'s registered name',
          design: RELAY_DESIGN, pattern: /#{TTY_OWNER}/,
          sites: %w[erlang/apps/erx_session/src/erx_session_relay.erl otp/lib/kernel/src/erx_output.erl
                    erlang/apps/erx/src/erx_console.erl erlang/apps/erx/src/erx_log_h.erl],
          seed: { 'erlang/apps/erx_shell/src/seeded.erl' =>
                    "f(Job) -> gen_server:call(erx_tty_owner, {open, Job, read}, infinity).\n" }
        ),
        # A relay of a tty other than the domain's line holds no name, so a
        # module that holds its pid could reach it without naming
        # erx_tty_owner; the request for an open made for reading, which
        # open_reader builds, is refused outside erx_session_relay. Other
        # requests built by hand pass it (TODO.md, relay).
        Chokepoints::ErlangForbidden.new(
          name: 'relay-requests', rule: 'only erx_session_relay builds {open, Holder, read}, the request for an ' \
                                        'open of the terminal made for reading',
          design: RELAY_DESIGN, strings: :blanked, pattern: OPEN_FOR_READING,
          sites: %w[erlang/apps/erx_session/src/erx_session_relay.erl],
          seed: { 'erlang/apps/erx_shell/src/seeded.erl' =>
                    "f(Relay, Job) -> gen_server:call(Relay, {open, Job, read}, infinity).\n" }
        )
      ]
    )
  end
end
