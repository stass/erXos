# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/erlang_apps'
require_relative '../../tools/lib/erx/generated'

# The network stack's host tests share this: a Minitest mixin that compiles
# erx_net from source with warnings as errors, with the host's Erlang model of
# erx_bytes' NIFs (test/erlang/host_bytes) and the given test modules, on
# stock's compiler and emulator (ERX_ERLC and ERX_ERL, which make check
# supplies), with the target build's flags (ErlangApps::FLAGS), and runs EUnit
# over the test modules. The modules go to erx_net/ebin in a temporary
# directory, so that code:priv_dir(erx_net) names erx_net/priv beside it, where
# tap: true builds the tap helper with its own makefile. With pkt: true it also
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
  INCLUDE = File.join(ROOT, 'erlang/apps/erx_net/include')
  HOST_BYTES = File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl')
  TESTS = File.join(ROOT, 'test/erlang')
  C_SRC = File.join(ROOT, 'erlang/apps/erx_net/c_src')
  DEADLINE = 300

  # Requires every EUnit case of modules, each test/erlang/MODULE.erl, to pass.
  # extra: further test/erlang module names to compile, such as an oracle.
  # tap: true builds the tap helper into erx_net's priv/.
  def assert_erx_net_eunit(*modules, extra: [], pkt: false, tap: false)
    output, status = run_erx_net_eunit(modules, extra: extra, pkt: pkt, tap: tap, fault: {})
    assert status.success?, output
    # EUnit words a run of exactly two tests "2 tests passed.", without "All".
    assert_match(/All \d+ tests passed|^\s*2 tests passed|Test passed/, output)
  end

  # Requires the EUnit cases of modules to fail once each erx_net module named in
  # fault is compiled with its seeded fault, given as [exact text, faulty text],
  # and returns EUnit's output for the caller to check which case failed.
  def refute_erx_net_eunit(*modules, fault:, extra: [])
    output, status = run_erx_net_eunit(modules, extra: extra, pkt: false, tap: false, fault: fault)
    refute status.success?, "the seeded fault #{fault.keys.join(', ')} passed:\n#{output}"
    assert_match(/Failed: [1-9]/, output)
    output
  end

  private

  def run_erx_net_eunit(modules, extra:, pkt:, tap:, fault:)
    Dir.mktmpdir('erx-net-eunit') do |work|
      ebin = File.join(work, 'erx_net', 'ebin')
      FileUtils.mkdir_p(ebin)
      build_tap_helper(File.join(work, 'erx_net', 'priv')) if tap
      includes = ['-I', Erx::Generated.path('erlang/apps/erx/include', root: ROOT), '-I', INCLUDE]
      if pkt
        tree = Erx::Dependencies.new(root: ROOT, runner: nil).fetched_tree('pkt')
        includes += ['-I', File.join(tree, 'include')]
        erlc(ebin, Dir[File.join(tree, 'src', '*.erl')].sort, includes: includes)
      end
      application = [APPLICATION, PORTABLE, CLIENT].flat_map { |dir| Dir[File.join(dir, '**', '*.erl')].sort }
                                           .map { |source| faulty_copy(work, source, fault) }
      sources = [HOST_BYTES, *application, *(extra + modules).map { |name| File.join(TESTS, "#{name}.erl") }]
      erlc(ebin, sources, includes: includes, flags: Erx::ErlangApps::FLAGS)

      list = "[#{modules.join(', ')}]"
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE.to_s, ENV.fetch('ERX_ERL'), '-noshell', '-pa', ebin,
                      '-eval', "halt(case eunit:test(#{list}, []) of ok -> 0; _ -> 1 end).",
                      chdir: work, stdin_data: '')
    end
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

  def erlc(ebin, sources, includes:, flags: [])
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, *includes, '-pa', ebin, '-o', ebin, *sources,
                                     stdin_data: '')
    assert status.success?, output
  end

  # The host C compiler builds the helper as c_src/Makefile does for a user, warnings as errors.
  def build_tap_helper(priv)
    output, status = Open3.capture2e('make', '-C', C_SRC, "PRIV=#{priv}", 'CFLAGS=-Werror', stdin_data: '')
    assert status.success?, output
  end
end
