# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_hosted'

# A suite that fills /tmp on erXos's hosted runtime fails at most its own
# cases: Common Test's logs live on a tree of their own, so the case after
# the fill is still logged, the suite's priv_dir is deleted when it ends,
# also when its init_per_suite fails, and the next suite runs. Needs the
# hosted runtime (make setup) and the stock oracle (make oracle-bootstrap).
class OracleLogTreeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FIXTURES = File.join(ROOT, 'test/fixtures/oracle_log_tree')
  # In name order: a fill that goes on, a fill whose init_per_suite fails, and the suite after them.
  SUITES = %w[oracle_fill_SUITE oracle_fill_fail_SUITE oracle_next_SUITE].freeze
  # /tmp's cap in the development manifest (`tmp 167772160`), and what
  # oracle_fill:fill/1 writes at most. The fill stops short of the cap by
  # what else /tmp holds: the suites' copy and the fill suites' own nodes.
  TMP_CAP = 160 << 20
  OTHER_TMP = 8 << 20
  MOST = 192 << 20

  def test_a_suite_that_fills_tmp_leaves_the_next_suite_running
    Dir.mktmpdir('erx-oracle-log-tree-') do |out|
      outcome = Erx::OracleHosted.new(root: ROOT, out: out, deadline: 600, group: 'kernel', source: FIXTURES)
                                 .run(SUITES)
      report = File.read(outcome.report)
      assert outcome.result.passed?, report
      verdicts = outcome.result.rows.to_h { |row| [[row.suite, row.testcase], row.verdict] }
      %w[oracle_fill_SUITE/after_fill oracle_fill_fail_SUITE/never oracle_next_SUITE/writes_priv].each do |name|
        assert_equal 'same', verdicts[name.split('/')], "#{name}\n#{report}"
      end
      filled = Dir.glob(File.join(out, 'logs/*erxos*.log')).sum([]) do |log|
        File.read(log).scan(/^erx-oracle-note (oracle_fill\w*) priv_dir (\d+)$/).map { |suite, bytes| [suite, Integer(bytes, 10)] }
      end
      assert_equal %w[oracle_fill_SUITE oracle_fill_fail_SUITE], filled.map(&:first), 'erXos notes each fill once, in order'
      filled.each do |suite, bytes|
        assert_operator bytes, :>, TMP_CAP - OTHER_TMP, "#{suite}'s fill reached /tmp's cap"
        assert_operator bytes, :<, MOST, "the cap stopped #{suite}'s fill"
      end
    end
  end
end
