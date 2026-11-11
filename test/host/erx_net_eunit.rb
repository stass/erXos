# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/erlang_apps'
require_relative '../../tools/lib/erx/erx_net_host'
require_relative '../../tools/lib/erx/generated'

# The network stack's host tests share this: a Minitest mixin that compiles
# erx_net from source with warnings as errors, its portable modules included,
# and the given test modules, on stock's compiler and emulator (ERX_ERLC and
# ERX_ERL, which make check supplies), with the target build's flags
# (ErlangApps::FLAGS), and runs EUnit over the test modules. The modules go to
# erx_net/ebin in a temporary directory, and c_src/Makefile builds erx_net/priv
# beside it (Erx::ErxNetHost): the library of the portable erx_bytes, so the
# stack runs on the same C as on erXos, and with tap: true the tap
# transport's NIF library too.
# With pkt: true it also
# compiles msantos/pkt from deps.lock's fetched tree, without -Werror since it
# is not erXos's code, for erx_net_pkt_oracle; a tree without it fails with
# the command that fetches it.
module ErxNetEunit
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_net/src')
  # The portable seam's modules, built only outside erXos (design-network-stack.md,
  # "Two places, four seams"); compiled after src/, whose behaviours they implement.
  PORTABLE = File.join(ROOT, 'erlang/apps/erx_net/portable')
  CLIENT = File.join(ROOT, 'erlang/apps/erx_net_client/src')
  # The client's erXos module, whose one call into erXos, `erx`, a test stands in for.
  CLIENT_ERXOS = File.join(ROOT, 'erlang/apps/erx_net_client/erxos')
  INCLUDE = File.join(ROOT, 'erlang/apps/erx_net/include')
  TESTS = File.join(ROOT, 'test/erlang')
  DEADLINE = 300
  # EUnit's own timeouts, the 5 s a case gets by default included, are multiplied by this
  # (its scale_timeouts option), so a case that waits on a loaded host's scheduler is not cut
  # short. DEADLINE still ends a run that hangs, and ends one first where a case's explicit
  # hang guard scaled by this passes it.
  TIMEOUT_SCALE = 3
  # OTP modules whose first use loads a NIF library or a socket layer, loaded with the
  # stack's own before EUnit starts.
  OTP_PRELOAD = %w[crypto gen_udp inet rand socket].freeze

  # Requires every EUnit case of modules, each test/erlang/MODULE.erl, to pass.
  # extra: further test/erlang module names to compile, such as an oracle.
  # tap: true builds the tap transport's NIF library into erx_net's priv/.
  def assert_erx_net_eunit(*modules, extra: [], pkt: false, tap: false)
    output, status = run_erx_net_eunit(modules, extra: extra, pkt: pkt, tap: tap, fault: {}, c_fault: {})
    assert status.success?, output
    # EUnit words a run of exactly two tests "2 tests passed.", without "All".
    assert_match(/All \d+ tests passed|^\s*2 tests passed|Test passed/, output)
  end

  # Requires the EUnit cases of modules to fail once each erx_net module named in
  # fault is compiled with its seeded fault, given as [exact text, faulty text],
  # and each c_src/ file named in c_fault built with its own, and returns EUnit's
  # output for the caller to check which case failed.
  def refute_erx_net_eunit(*modules, fault: {}, c_fault: {}, extra: [], tap: false)
    output, status = run_erx_net_eunit(modules, extra: extra, pkt: false, tap: tap, fault: fault, c_fault: c_fault)
    seeds = [*fault.keys, *c_fault.keys].join(', ')
    refute status.success?, "the seeded fault #{seeds} passed:\n#{output}"
    if output.match?(/\*timed out\*|were cancelled/) && !output.match?(/Failed: [1-9]/)
      flunk "the seeded fault #{seeds} ended in cancelled cases (a timeout, a failed setup or a dead test " \
            "process), not in a failing case:\n#{output}"
    end
    assert_match(/Failed: [1-9]/, output)
    output
  end

  private

  def run_erx_net_eunit(modules, extra:, pkt:, tap:, fault:, c_fault:)
    Dir.mktmpdir('erx-net-eunit') do |work|
      ebin = Erx::ErxNetHost.lay_out(work, erl: ENV.fetch('ERX_ERL'), tap: tap, c_src: faulty_c_src(work, c_fault))
      includes = ['-I', Erx::Generated.path('erlang/apps/erx/include', root: ROOT), '-I', INCLUDE]
      if pkt
        tree = Erx::Dependencies.new(root: ROOT, runner: nil).fetched_tree('pkt')
        includes += ['-I', File.join(tree, 'include')]
        erlc(ebin, Dir[File.join(tree, 'src', '*.erl')].sort, includes: includes)
      end
      application = [APPLICATION, PORTABLE, CLIENT, CLIENT_ERXOS].flat_map { |dir| Dir[File.join(dir, '**', '*.erl')].sort }
                                           .map { |source| faulty_copy(work, source, fault) }
      sources = [*application, *(extra + modules).map { |name| File.join(TESTS, "#{name}.erl") }]
      erlc(ebin, sources, includes: includes, flags: Erx::ErlangApps::FLAGS)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE.to_s, ENV.fetch('ERX_ERL'), '-noshell', '-pa', ebin,
                      '-eval', eunit_call(modules, preload: preloaded(sources, tap)), chdir: work, stdin_data: '')
    end
  end

  # The modules to load before EUnit starts: each source of the run, and the OTP modules of
  # OTP_PRELOAD. erx_tap_nif is left out unless the run builds its library, since its
  # on_load fails without it.
  def preloaded(sources, tap)
    names = sources.map { |source| File.basename(source, '.erl') }
    names -= ['erx_tap_nif'] unless tap
    [*names, *OTP_PRELOAD]
  end

  # The Erlang expression a run evaluates: it first loads preload, so the code server's work,
  # a NIF library's load included, is done before the first case starts and no case's
  # timeout covers it, then runs EUnit over modules with its timeouts scaled. A module that
  # fails to load is left for the case that uses it to report.
  def eunit_call(modules, preload:)
    "_ = code:ensure_modules_loaded([#{preload.join(', ')}]), " \
      "halt(case eunit:test([#{modules.join(', ')}], [{scale_timeouts, #{TIMEOUT_SCALE}}]) of ok -> 0; _ -> 1 end)."
  end

  # Source itself, or for a module named in fault a copy in work with its exact
  # text replaced by the faulty text.
  def faulty_copy(work, source, fault)
    exact, faulty = fault[File.basename(source, '.erl')]
    return source unless exact

    text = File.read(source)
    raise "#{source} lacks the text its seeded fault replaces" unless text.include?(exact)

    File.join(work, File.basename(source)).tap { |copy| File.write(copy, text.sub(exact, faulty)) }
  end

  # c_src/ itself, or with c_fault a copy in work whose named files have their exact
  # text replaced by the faulty text.
  def faulty_c_src(work, c_fault)
    return Erx::ErxNetHost::C_SRC if c_fault.empty?

    copy = File.join(work, 'c_src')
    FileUtils.cp_r(Erx::ErxNetHost::C_SRC, copy)
    c_fault.each do |name, (exact, faulty)|
      file = File.join(copy, name)
      text = File.read(file)
      raise "#{name} lacks the text its seeded fault replaces" unless text.include?(exact)

      File.write(file, text.sub(exact, faulty))
    end
    copy
  end

  def erlc(ebin, sources, includes:, flags: [])
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, *includes, '-pa', ebin, '-o', ebin, *sources,
                                     stdin_data: '')
    assert status.success?, output
  end
end
