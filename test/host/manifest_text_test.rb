# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest_text'
require_relative '../../tools/lib/erx/platform'

# ManifestText, the one edit harnesses make to a manifest's numbers
# (tools/lib/erx/manifest_text.rb).
class ManifestTextTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCE = "# memory 1 in a comment\nprincipal system\n  memory 10\n  domains 2\nprincipal other\n  memory 20\n" \
           "machine\n  root_memory 100\n  max_domains 4\n"

  # A field is reached through its record: the other principal's memory, the comment
  # and every other line stay as they were.
  def test_grow_and_set_edit_only_the_named_records_field
    grown = Erx::ManifestText.grow(SOURCE, { ['principal system', 'memory'] => 5, %w[machine root_memory] => -1 })
    assert_equal SOURCE.sub('  memory 10', '  memory 15').sub('  root_memory 100', '  root_memory 99'), grown
    assert_equal SOURCE.sub('  max_domains 4', '  max_domains 7'), Erx::ManifestText.set(SOURCE, %w[machine max_domains] => 7)
  end

  # Every edit the harnesses make finds its field in the development manifest.
  def test_the_development_manifest_has_every_field_the_harnesses_edit
    source = Erx::Platform.development(ROOT).manifest_source(ROOT)
    fields = [%w[machine root_memory], %w[machine system_baseline], %w[machine max_domains], %w[machine max_connections],
              ['principal system', 'memory'], ['principal system', 'domains'], ['runtime_limits system', 'tmp']]
    assert_equal source, Erx::ManifestText.grow(source, fields.to_h { |field| [field, 0] })
  end

  # A record or field that is not there exactly once, a value that is not a decimal
  # number, and a result below zero are refused, never applied somewhere else.
  def test_an_edit_that_has_no_one_place_is_refused
    { %w[machine absent] => 1, ['principal absent', 'memory'] => 1, %w[nothing root_memory] => 1,
      %w[machine root_memory] => -101 }.each do |field, number|
      assert_raises(Erx::Error, field.join(' ')) { Erx::ManifestText.grow(SOURCE, { field => number }) }
    end
    ["machine\n  root_memory 1\nmachine\n  root_memory 2\n", "machine\n  root_memory 1\n  root_memory 2\n",
     "machine\n  root_memory 0x10\n", "machine\n  root_memory 1_000\n", "machine\n# a comment\n  root_memory 1\n"]
      .each do |source|
        assert_raises(Erx::Error, source) { Erx::ManifestText.grow(source, { %w[machine root_memory] => 1 }) }
      end
  end

  # A domain web with its limits, share and runtime limits (the last also named by the
  # other domain's limits), a unit it holds on a platform unit of two devices, and a
  # service of its own with its display record and the system domain's facet of it.
  DOMAINS = "# web's records\nprincipal system\n  memory 100\n  domains 3\nshare web\n  quota_ns 1\n" \
            "runtime_limits web\n  tmp 0\nlimits web\n  memory 10\n  outer 1\n  grant @share.web\n" \
            "  runtime_limits @runtime_limits.web\nlimits other\n  memory 5\n  outer 1\n  grant @share.users\n" \
            "  runtime_limits @runtime_limits.web\nmachine\n  root_memory 200\n  max_domains 3\n  max_connections 9\n" \
            "unit gpu\n  placement \"display\"\n  holder @domain.web\ndomain web\n  principal @principal.system\n" \
            "  limits @limits.web\nservice relay\n  server @domain.web\n  interface web\ndisplay relay\n  policy single\n" \
            "facet relay\n  grantee system\n  service @service.relay\ndomain other\n  principal @principal.system\n" \
            "  limits @limits.other\n"
  UNITS = [{ 'key' => 'display', 'devices' => [{ 'dma_memory' => 4 }, { 'dma_memory' => 3 }] }].freeze

  def record(header) = DOMAINS[/^#{header}\n(?:  .*\n)*/]

  # Taking web out takes its records and those only it named, keeps the runtime limits the
  # other domain's limits still name and every comment, and gives back its room: its
  # budgets (10 and 1) from the principal and root_memory, its unit's DMA memory (4 and 3)
  # from root_memory, and one domain and one connection.
  def test_without_domain_takes_its_records_and_gives_back_its_room
    gone = ['share web', 'limits web', 'unit gpu', 'domain web', 'service relay', 'display relay', 'facet relay']
    expected = gone.reduce(DOMAINS) { |text, header| text.sub(record(header), '') }
                   .sub("  memory 100\n  domains 3\n", "  memory 89\n  domains 2\n")
                   .sub("  root_memory 200\n  max_domains 3\n  max_connections 9\n",
                        "  root_memory 182\n  max_domains 2\n  max_connections 8\n")
    assert_equal expected, Erx::ManifestText.without_domain(DOMAINS, 'web', units: UNITS)
  end

  # A domain that is not there, whose service is granted to a session or another domain, which
  # leaves a record naming one it took, or whose unit is on no platform unit, is refused.
  def test_without_domain_refuses_what_it_cannot_take_whole
    [['absent', DOMAINS, /exactly one record @domain.absent/],
     ['web', DOMAINS.sub("  grantee system\n", "  grantee @session.system\n"), /granted by facet relay/],
     ['web', "#{DOMAINS}start system\n  display @service.relay\n", /start system names a record/],
     ['web', "#{DOMAINS}introduce @domain.other @domain.web\n", /introduce @domain.other @domain.web names a record/],
     ['web', DOMAINS.sub('placement "display"', 'placement "spare"'), /placed on "spare"/],
     ['web', DOMAINS.sub("  limits @limits.web\n", "  limits @limits.web\n# env follows\n  env \"A=1\"\n"),
      /line \d+ is a field outside a record/]].each do |name, source, message|
      error = assert_raises(Erx::Error) { Erx::ManifestText.without_domain(source, name, units: UNITS) }
      assert_match message, error.message
    end
  end
end
