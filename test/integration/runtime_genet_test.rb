# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/runtime'

# The network stack over erx_genet on the hosted runtime's stand-in GENET: the transport's
# whole sequence (identify, reset, the PHY over MDIO, negotiate, the line) and the register
# ring's posts and completions both ways, under UDP and TCP from the stack's own sockets.
# test/fixtures/erx_genet_hosted_run.erl runs the stand-in's engine and plays the far end.
# `make check-runtime-hosted` builds the runtime and runs this.
class RuntimeGenetTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  BUDGET_SECONDS = 60
  FIXTURE = File.join(ROOT, 'test/fixtures/erx_genet_hosted_run.erl')
  CORE = File.join(ROOT, 'erlang/apps/erx_net/erxos/erx_genet_core.erl')
  # The stack's portable runtime seam, which an erXos build leaves out: on the hosted runtime
  # no other domain asks the stack for anything, as outside erXos.
  LOCAL = File.join(ROOT, 'erlang/apps/erx_net/portable/erx_net_local.erl')
  # The network domain's applications, which the hosted release does not ship.
  NETWORK_APPS = %w[erx_net erx_net_client].freeze
  # The transmit pieces in the wrong order: every frame reaches the wire scrambled.
  PIECE_ORDER = ['[{out, B} || B <- Leaves];', '[{out, B} || B <- lists:reverse(Leaves)];'].freeze
  # Loads each `Name Base64` line of standard input as a module, to its end.
  LOAD_ALL = 'Load = fun Load() -> case io:get_line("") of eof -> ok; Line -> ' \
             '[Name, Beam] = string:split(string:trim(Line), " "), ' \
             '{module, _} = code:load_binary(list_to_atom(Name), Name, base64:decode(Beam)), Load() end end, ' \
             'ok = Load(), '

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_udp_and_tcp_cross_the_stand_in_genet
    output = run_fixture
    assert_match(/^udp ok$/, output)
    assert_match(/^tcp ok$/, output)
    assert_equal 'ok', output.lines(chomp: true).last, output
    puts output[/^wire .*$/]
  end

  def test_pieces_out_of_order_fail_it
    output = run_fixture(seeded_core: compiled(CORE, seeded(File.read(CORE), *PIECE_ORDER)))
    refute_match(/^udp ok$/, output)
    refute_equal 'ok', output.lines(chomp: true).last, output
  end

  private

  def seeded(source, anchor, replacement)
    assert_equal 1, source.scan(anchor).size, "no single anchor #{anchor}"
    source.sub(anchor, replacement)
  end

  # The network applications as the runtime's build compiled them, erx_net_local, the fixture and a seeded
  # erx_genet_core in place of the built one when given, each loaded from standard input, since
  # the runtime reads no host directory and the command line's page has no room for them;
  # then the fixture's run.
  def run_fixture(seeded_core: nil)
    beams = [*NETWORK_APPS.flat_map { |app| built_beams(app) },
             ['erx_net_local', compiled(LOCAL, File.read(LOCAL))],
             ['erx_genet_hosted_run', compiled(FIXTURE, File.read(FIXTURE))],
             *(seeded_core ? [['erx_genet_core', seeded_core]] : [])]
    output, = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                              OUTPUT.beam, OUTPUT.archive, '-noshell',
                              '-eval', "#{LOAD_ALL}erx_genet_hosted_run:run(), halt().",
                              stdin_data: beams.map { |name, beam| "#{name} #{beam}\n" }.join)
    output
  end

  def built_beams(app)
    Dir[File.join(OUTPUT.root, 'lib', app, 'ebin', '*.beam')].sort.map do |path|
      [File.basename(path, '.beam'), [File.binread(path)].pack('m0')]
    end
  end

  # A module's source compiled by the stock compiler, as base64.
  def compiled(path, source)
    name = File.basename(path, '.erl')
    Dir.mktmpdir("#{name}-") do |work|
      copy = File.join(work, "#{name}.erl")
      File.write(copy, source)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', File.join(ROOT, 'erlang/apps/erx_net/include'),
                                       '-o', work, copy, stdin_data: '')
      assert status.success?, output
      [File.binread(File.join(work, "#{name}.beam"))].pack('m0')
    end
  end
end
