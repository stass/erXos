# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/build_facts'
require_relative '../../tools/lib/erx/fiasco'

# The build-facts file the image build writes for uname (Erx::BuildFacts):
# its text, the configuration's name, the kernel's, and the refusal of a
# fact erx_build would not read. test/erlang/erx_cmd_uname_tests.erl reads
# the same text back with erx_build:parse_facts/1.
class BuildFactsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  BuildFacts = Erx::BuildFacts
  KNOWN = BuildFacts::Facts.new(revision: 'n1234-5e45e725588e', date: 1_794_160_931,
                                configuration: 'qemu-virt/development', kernel: 'fiasco-50bbe8a98119')
  # The bytes erx_cmd_uname_tests.erl's FACTS holds.
  TEXT = "revision n1234-5e45e725588e\ndate 1794160931\n" \
         "configuration qemu-virt/development\nkernel fiasco-50bbe8a98119\n"

  def test_the_file_is_one_line_per_fact_in_order
    assert_equal TEXT, BuildFacts.render(KNOWN)
  end

  def test_a_fact_the_build_could_not_determine_is_written_unknown
    facts = KNOWN.with(revision: nil, date: nil)
    assert_equal TEXT.sub('n1234-5e45e725588e', 'unknown').sub('1794160931', 'unknown'), BuildFacts.render(facts)
  end

  def test_the_configuration_is_the_platform_and_the_build_kind
    assert_equal 'qemu-virt/development', BuildFacts.configuration(platform: 'qemu-virt', build_kind: 'development')
    assert_equal 'rpi4/release', BuildFacts.configuration(platform: 'rpi4', build_kind: 'release')
  end

  def test_the_kernel_is_fiasco_and_its_recorded_revision
    name = Erx::Fiasco.new(root: ROOT, runner: nil).kernel_name
    revision = Erx::Origin.new(root: File.join(ROOT, 'fiasco/kernel')).inventory.fetch('revision')
    assert_equal "fiasco-#{revision[0, 12]}", name
    assert_match BuildFacts::SHAPES.fetch(:kernel), name
  end

  def test_a_fact_of_the_wrong_shape_is_refused
    [{ revision: 'a b' }, { revision: "evil\e]8;;" }, { revision: '-dash' }, { revision: 'a' * 161 },
     { revision: 'master-n1234-5e45e725588e' }, { revision: 'n0-0123456789ab' }, { revision: '0123456789AB' },
     { date: -1 }, { date: 10**12 }, { configuration: 'QEMU-VIRT/DEVELOPMENT' },
     { configuration: 'qemu-virt' }, { kernel: 'Fiasco-1' }, { kernel: "fiasco\n" }].each do |changed|
      error = assert_raises(Erx::Error, changed.inspect) { BuildFacts.render(KNOWN.with(**changed)) }
      assert_includes error.message, changed.keys.first.to_s
    end
  end
end
