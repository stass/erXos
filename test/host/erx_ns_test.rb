# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/app_package'

# Runs test/erlang/erx_ns_tests.erl, the EUnit cases of the namespace table's one
# writer, against erx_ns compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the stub of
# prim_file the cases start it with. An image mount runs the EROFS reader and its funnel
# over a fixture image (ERX_EROFS_FIXTURES) in a RAM window of erx_erofs_tests, and its
# log line reaches the case through a stub of erx_log, which sends it to the process
# registered as erx_ns_log. An app mount, {erofs, app}, reads a package-shaped file
# (write_package: a header block, the compact fixture image and the tree the packer's
# writer makes for it, ERX_VERITY_CASES) through a grant of erx_fs_test_tree, its record
# from a stand-in of erx_connections that answers what the case put in a persistent term.
class ErxNsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  # The application holding erx_ns, compiled whole (ErlangBuild), and the modules the cases
  # run it with: the prim_file stub, the host stand-in of erx_bytes and the suites.
  APPLICATIONS = %w[erx erx_files].freeze
  TESTS = %w[test/erlang/erx_ns_prim_stub.erl test/erlang/erx_ns_tests.erl
             test/erlang/host_bytes/erx_bytes.erl
             test/erlang/erx_fs_test_tree.erl test/erlang/stand_in/erx_dist.erl
             test/erlang/erx_erofs_tests.erl].freeze
  INCLUDES = %w[otp/lib/kernel/include].freeze
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')
  # This text is compiled in place of the application's erx_log (a stub), so the case sees
  # the log line a mount writes.
  LOG_STUB = <<~ERLANG
    -module(erx_log).
    -export([debug/1]).
    debug(Line) ->
        case whereis(erx_ns_log) of
            undefined -> ok;
            Log -> Log ! {log, Line}, ok
        end.
  ERLANG
  LOG = 'erlang/apps/erx/src/erx_log.erl'
  # The agent as erx_ns asks it for the app's record: what the case put, else none.
  CONNECTIONS_STUB = <<~ERLANG
    -module(erx_connections).
    -export([app_held/0]).
    app_held() -> persistent_term:get(erx_connections_app, {error, enoent}).
  ERLANG
  CONNECTIONS = 'erlang/apps/erx/src/erx_connections.erl'
  # Stock's prim_file has no erx_fid/0, so the 9P client compiles with a stand-in that
  # hands out fresh fids, as test/host/erx_file_remote_reply_test.rb does.
  FILE_REMOTE = 'otp/erts/preloaded/src/erx_file_remote.erl'
  FID = "fid() ->\n    prim_file:erx_fid().\n"
  STAND_IN_FID = "fid() ->\n    erlang:unique_integer([positive]).\n"
  # Seeded faults of the 9P client (design-files.md, Erlang clients): the text replaced,
  # its replacement and the case that must fail. An attach sent again ahead of every
  # exchange's requests, its reply dropped so each operation still answers; and the
  # grammar's full decode back in the client's refusals, so a request only the grammar
  # refuses never reaches the grant's funnel.
  ClientFault = Data.define(:name, :from, :to, :caught_by)
  CLIENT_FAULTS = [
    ClientFault.new(name: 'an attach sent with every exchange',
                    from: "        none -> sent(Pid, Requests);\n",
                    to: "        none -> tl(sent(Pid, [{attach, 0, ?ERX_P9_NOFID, <<>>, <<\"data\">>, 0} | Requests]));\n",
                    caught_by: 'a_file_call_walks_from_nofid_and_never_attaches_test'),
    ClientFault.new(name: "the grammar's full decode back in the client's refusals",
                    from: 'case {dot_walk(Request), ',
                    to: 'case {dot_walk(Request) orelse element(1, erx_9p_grammar:decode_request(Request)) =:= error, ',
                    caught_by: 'the_funnel_alone_checks_a_request_against_the_grammar_test')
  ].freeze
  PACKAGE_SALT = ("\x0d".b * 9).freeze
  NS = 'erlang/apps/erx/src/erx_ns.erl'
  # A seeded erx_facets:table/1 that derives no nofollow mark, so a resolution follows a
  # link on a drive: a_media_facet_entry_follows_no_link must catch it.
  FACETS = 'otp/erts/preloaded/src/erx_facets.erl'
  MEDIA_MARK = "marked(?ERX_SERVICE_MEDIA, Entry) -> Entry\#{nofollow => true};\n"
  # A seeded erx_ns whose app mount also takes a {layout, Place, Layout} source, the
  # place and layout from the caller rather than the agent's record, so an app could
  # mount any file of its grant with a layout it chose: app_mount_refusals must catch it.
  # Each pair is the text the seed goes before and the seed.
  CALLER_LAYOUT = [
    ["checked({mount, To, {erofs, app}, Options}, Table) ->\n", <<~'ERLANG'],
      checked({mount, To, {erofs, {layout, Place, Layout}}, Options}, Table) ->
          maybe
              {ok, Rights} ?= image_rights(Options),
              {ok, Point} ?= new_point(To, Table),
              {ok, {mount_layout, Point, Rights, Place, Layout}}
          end;
    ERLANG
    ["mounted({mount_app, Point, Rights}) ->\n", <<~'ERLANG']
      mounted({mount_layout, Point, Rights, {Facet, Names}, Layout}) ->
          maybe
              {ok, Grant} ?= erx_facets:file_grant(Facet, Rights),
              {ok, Fid} ?= erx_file_remote:open_fid(Grant, Names),
              {ok, Fs} ?= image(Grant, Fid, Layout),
              {ok, {mount, Point, {erofs, Fs}, Rights, {Grant, Fid}}}
          end;
    ERLANG
  ].freeze

  def test_writer_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_resolution_that_marks_no_media_entry_is_caught
    facets = File.read(File.join(ROOT, FACETS))
    assert_equal 1, facets.scan(MEDIA_MARK).size, 'erx_facets has no media mark clause to remove'
    output, status = eunit(FACETS => facets.sub(MEDIA_MARK, ''))
    refute status.success?, output
    assert_match(/a_media_facet_entry_follows_no_link\.\.\.\*failed\*/, output)
    assert_match(/Failed: 1\./, output)
  end

  def test_an_app_mount_taking_the_callers_layout_is_caught
    ns = CALLER_LAYOUT.reduce(File.read(File.join(ROOT, NS))) do |text, (before, seed)|
      raise "erx_ns has no #{before.strip} to seed before" unless text.include?(before)

      text.sub(before) { seed + before }
    end
    output, status = eunit(NS => ns)
    refute status.success?, output
    assert_match(/app_mount_refusals\.\.\.\*failed\*/, output)
    assert_match(/Failed: 1\./, output)
  end

  # One test per client fault, named by its place in CLIENT_FAULTS.
  CLIENT_FAULTS.each_with_index do |fault, index|
    define_method(:"test_client_fault_#{index}_is_caught") do
      text = file_remote
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: the text to seed not found once"
      output, status = eunit(FILE_REMOTE => text.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.\*failed\*/, output, fault.name)
    end
  end

  private

  def eunit(seeded = {})
    Dir.mktmpdir('erx-ns-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                replaced: { LOG => LOG_STUB, CONNECTIONS => CONNECTIONS_STUB,
                                            FILE_REMOTE => file_remote, **seeded }, includes: INCLUDES)
      write_package(work)
      Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES, 'ERX_VERITY_CASES' => work }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_ns_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end

  # The 9P client with its fid draw replaced by the stand-in.
  def file_remote
    text = File.read(File.join(ROOT, FILE_REMOTE))
    raise 'the client has no fid/0 to stand in for' unless text.include?(FID)

    text.sub(FID) { STAND_IN_FID }
  end

  # package.img, a package's shape: a header block of 0xEE, the compact image and its
  # tree; verity.terms, its layout as {"package", Layout}.
  def write_package(work)
    image = File.binread(File.join(FIXTURES, 'compact.img'))
    tree = Erx::AppPackage.verity_tree(image, salt: PACKAGE_SALT)
    before = "\xee".b * 4096
    File.binwrite(File.join(work, 'package.img'), before + image + tree.bytes)
    layout = { image_offset: before.bytesize, image_length: image.bytesize, tree_offset: before.bytesize + image.bytesize,
               tree_length: tree.bytes.bytesize, salt: PACKAGE_SALT, root_hash: tree.root_hash }
    pairs = layout.map { |key, value| "#{key} => #{value.is_a?(String) ? "<<#{value.bytes.join(',')}>>" : value}" }
    File.write(File.join(work, 'verity.terms'), "{\"package\", \#{#{pairs.join(', ')}}}.\n")
  end
end
