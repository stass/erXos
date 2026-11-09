# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'

# The widget format (docs/design-abi.md, "Widget format"): the generator's refusals of
# a malformed ui.txt, and the EUnit cases of erx_ui_schema, generated from
# abi/formats/ui.txt into build/gen, on stock's emulator (ERX_ERL and ERX_ERLC).
class ErxUISchemaTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  LIMITS = { 'web_ui_op_max' => 65_024, 'ui_children' => 1024 }.freeze
  BASE = <<~UI
    ui 1
      text caption 4096 utf8
      integer bound -100 100
      list items caption 4
      prop key 1 key common
      prop text 2 caption
      prop min 3 bound default 0
      prop max 4 bound default 10
      prop value 5 bound
      prop flag 6 boolean
      prop on_change 7 event detail state
  UI

  def test_generated_schema_cases_pass_under_eunit
    module_text = File.binread(File.join(ROOT, Erx::Generated::OUTPUT, Erx::ABI::UIEmitter::ERLANG_PATH))
    Dir.mktmpdir('erx-ui-schema-test') do |work|
      module_path = File.join(work, 'erx_ui_schema.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, module_path,
                                       File.join(ROOT, 'test/erlang/erx_ui_schema_tests.erl'), stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_ui_schema_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_base_source_is_accepted
    schema = read("#{BASE}  kind slider 1\n    prop min\n    prop max\n    prop value state within min max\n    prop on_change\n")
    assert_equal 13 + 5 + 5 + 5 + 1, schema.insert_max.fetch('slider')
  end

  def test_generator_refusals
    {
      'duplicate number' => "  prop other 2 caption\n",
      'duplicate ui name' => "  prop text 9 caption\n",
      'duplicate ui name image' => "  integer image 0 1\n",
      'outside 1..255' => "  kind big 256\n",
      'not a raster image/ type' => "  image svg 1 \"image/svg+xml\"\n",
      'state event without one state property' => "  kind box 1\n    prop on_change\n",
      'both integers, the bound taken with a default' => "  kind s 1\n    prop value within min flag\n    prop flag\n",
      'an integer indexing a list' => "  kind s 1\n    prop value index text\n    prop text\n",
      'a fixed boolean hiding' => "  kind s 1\n    prop flag hides text\n    prop text\n",
      'is common to every kind' => "  kind s 1\n    prop key\n",
      'exceeds web_ui_op_max' => "  list big caption 16\n  prop big 8 big\n  kind s 1\n    prop big\n",
      'only it, has the type key' => "  prop id 8 key\n",
      'only a text or presentation property carries a status' => "  prop low 8 bound status\n",
      'follows the image types it takes' => "  prop picture 8 image\n",
      'must lie below the high bound' => "  prop top 8 bound default 0\n  kind s 1\n    prop min\n    prop top\n    prop value within min top\n"
    }.each do |message, addition|
      error = assert_raises(Erx::ABI::SchemaError) { read(BASE + addition) }
      assert_includes error.message, message
    end
  end

  private

  def read(text)
    declarations = Erx::ABI::Syntax.parse(text, path: Erx::ABI::UI::SOURCE)
    Erx::ABI::UI.validate(declarations, limits: LIMITS, types: {})
  end
end
