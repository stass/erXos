# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/runtime'

# A queued message whose term is a literal and whose seq_trace token is on the receiver's
# heap keeps its token through the collection of the literal's area
# (test/fixtures/literal_token_probe.erl). When the collection copies only the literal into
# a fragment of the message's own, the next garbage collection leaves the token in a freed
# heap: the hosted runtime then reads a wrong token, or faults where the backend has taken
# the freed pages away. Stock OTP 29.1.2 aborts on the same probe.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older than the
# tree, it fails: nothing is skipped.
class RuntimeLiteralTokenTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  PROBE = 'literal_token_probe'
  # Twenty rounds take well under a second; the budget is a boot on a loaded host.
  BUDGET_SECONDS = 60
  COMPILE_SECONDS = 120

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_queued_literal_keeps_its_token_through_the_area_collection
    load_probe = "{module, #{PROBE}} = code:load_binary(#{PROBE}, \"#{PROBE}\", " \
                 "base64:decode(string:trim(io:get_line(\"\"))))"
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge('ERL_CRASH_DUMP_BYTES' => '0')
    output, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s, OUTPUT.beam,
                                     OUTPUT.archive, '-noshell', '-eval', "#{load_probe}, #{PROBE}:main().",
                                     stdin_data: "#{compiled_probe}\n")
    assert status.success?, "exit #{status.exitstatus.inspect} (124 is the deadline), " \
                            "signal #{status.termsig.inspect}\n#{output}"
    assert_match(/^literal token probe: \d+ rounds, token intact$/, output)
  end

  private

  # The probe's BEAM, in base64, for standard input: the release has no compiler and reaches no
  # host file, and the boot page's limit on strings leaves no room for it among the arguments.
  def compiled_probe
    erlc = File.join(File.dirname(Erx::Oracle.new(root: ROOT).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR)), 'erlc')
    Dir.mktmpdir('erx-literal-token-') do |directory|
      log, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', COMPILE_SECONDS.to_s, erlc,
                                    '-o', directory, File.join(ROOT, 'test/fixtures', "#{PROBE}.erl"), stdin_data: '')
      assert status.success?, "erlc exit #{status.exitstatus} (124 is the deadline)\n#{log}"
      [File.binread(File.join(directory, "#{PROBE}.beam"))].pack('m0')
    end
  end
end
