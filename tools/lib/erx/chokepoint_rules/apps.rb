# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    APPS = 'docs/design-apps.md'

    # The start table's rules (AP1, AP2): who starts a session and who names
    # its display. StartCallers, in Checks, reads the Erlang sources for them.
    declare_group(
      rules: [
        Chokepoints::Elsewhere.new(
          name: 'starter-reach', rule: 'erx_starter reaches the domain service only through erx_domain:start_session/2 ' \
                                       'and erx_domain:stop/2 (reading a handle with id/1 and pid/1), and calls nothing through a variable or ' \
                                       'macro module or apply',
          design: "#{APPS}#invariants", check: 'StartCallers, in Checks', test: 'test/host/apps_chokepoints_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'start-callers', rule: 'only erx_console and erx_starter_keeper call erx_domain:start_session/2, and only ' \
                                       "erx_domain's own modules name its service, erx_domain_srv; the web login " \
                                       'joins the callers when it is built',
          design: "#{APPS}#invariants", check: 'StartCallers, in Checks', test: 'test/host/apps_chokepoints_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'start-display', rule: 'only erx_starter passes display or default_display to erx_domain:start_session/2',
          design: "#{APPS}#verification-and-testing", check: 'StartCallers, in Checks',
          test: 'test/host/apps_chokepoints_test.rb'
        )
      ]
    )
  end
end
