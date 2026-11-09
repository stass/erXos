# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs the EUnit cases of test/erlang/inet_dns_tests.erl against the tree's inet_dns,
# otp/lib/kernel/src/inet_dns.erl, loaded over the kernel's, so the run is -nostick.
class InetDnsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  KERNEL = File.join(ROOT, 'otp/lib/kernel')
  TESTS = File.join(ROOT, 'test/erlang/inet_dns_tests.erl')
  SOURCE = File.join(KERNEL, 'src/inet_dns.erl')
  DEADLINE = '300'

  def test_undecodable_record_data_is_kept_raw_by_the_trees_decoder
    Dir.mktmpdir('erx-inet-dns') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', File.join(KERNEL, 'src'),
                                       '-I', File.join(KERNEL, 'include'), '-o', work, SOURCE, TESTS, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-nostick',
                                       '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  def eval_text
    'code:purge(inet_dns), {module, inet_dns} = code:load_abs("inet_dns"), ' \
      'halt(case eunit:test(inet_dns_tests, []) of ok -> 0; _ -> 1 end).'
  end
end
