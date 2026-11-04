# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The kernel log core, and the hosted backend's log sink that writes it
    # to standard error.
    LOG_CORE = 'kernel/core/log.c'

    declare_group(
      unchecked_objects: %w[liberx/backend/hosted/log.c liberx/backend/hosted/log.h],
      rules: [
        Chokepoints::Forbidden.new(
          name: 'log-raw-private',
          rule: "only #{LOG_CORE} and the log's header name the ring, the text store and the raw append, " \
                'so a record\'s text comes only through erx_log_escape',
          design: "#{KERNEL}#chokepoint-checks",
          scope: ERXOS_C,
          pattern: /\b(?:raw_ring|raw_text|erx_log_raw_[a-z_]+)\b/,
          sites: [Chokepoints::Site.new(glob: LOG_CORE), Chokepoints::Site.new(glob: 'include/erx/log.h')],
          seed: { 'kernel/core/seeded.c' => "void f(erx_log_t *log) { log->raw_ring[0] = 27; }\n",
                  'liberx/backend/hosted/seeded.c' => "void f(erx_log_t *log) { log->raw_text[0] = 27; }\n",
                  'test/fixtures/log_driver.c' => "void f(void) { erx_log_raw_append(0, 0, 0, 0); }\n" }
        ),
        # ERX_LOG_FORMAT joins "" to its format, so only a string literal compiles.
        Chokepoints::Forbidden.new(
          name: 'log-format-literal',
          rule: "every call of the log's formatting function goes through ERX_LOG_FORMAT, so every format is a " \
                'string literal',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: /\berx_log_format\b/,
          sites: [Chokepoints::Site.new(glob: LOG_CORE), Chokepoints::Site.new(glob: 'include/erx/log.h')],
          seed: { 'kernel/core/seeded.c' => "void f(erx_log_t *log, const char *name) { erx_log_format(log, 1, 0, name); }\n",
                  'fiasco/kernel/src/erx/seeded.cpp' => "void f() { erx_log_format(log, 1, 0, name); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'hosted-log-sink',
          rule: "only the hosted backend's log sink writes bytes to its console, standard error",
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: false, extra: ['liberx/backend/hosted/**/*']),
          pattern: /\b(?:write|writev|pwrite|pwritev|fwrite|fputs|fputc|fprintf|vfprintf|printf|vprintf|dprintf|vdprintf|
                         puts|putc|putchar|perror|err|errx|warn|warnx|syscall|stderr|stdout|STDERR_FILENO|STDOUT_FILENO)\b/x,
          sites: [Chokepoints::Site.new(glob: 'liberx/backend/hosted/log.c', permits: /\A(?:write|STDERR_FILENO)\z/)],
          seed: { 'liberx/backend/hosted/seeded.c' => "void f(void) { write(2, \"x\", 1); }\n",
                  'liberx/backend/hosted/log.c' => "void f(void) { fprintf(stderr, \"x\"); }\n" }
        )
      ]
    )
  end
end
