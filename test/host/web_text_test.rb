# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/line_escape'
require_relative '../../tools/lib/erx/web_stage'

# The web client's line escape and /proc encoder against their twins
# (docs/design-web.md, "Verification and testing"): escapeLine of
# web/src/text.ts against erx_text:escape_line/1 and Erx::LineEscape, and
# procName of web/src/names.ts against erx_procfs_core:name/1, over the
# attributed-text corpus of test/fixtures/line_escape_vectors.json and random
# bytes. Erlang runs on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). Then a client that decodes with TextDecoder, which replaces
# an invalid byte with U+FFFD, must disagree on 0xC0.
class WebTextTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/erx_text_tables.erl erlang/apps/erx/src/erx_text.erl
               build/gen/erlang/apps/erx/src/generated/erx_schema.erl
               erlang/apps/erx_files/src/erx_procfs_core.erl].map { |path| File.join(ROOT, path) }.freeze
  # Reads x-prefixed hexadecimal lines and writes each input's escape and entry name the same way.
  ERLANG = <<~ERL.gsub("\n", ' ')
    {ok, In} = file:read_file("in.txt"),
    Hex = fun(B) -> [$x, binary:encode_hex(B)] end,
    Out = [[Hex(erx_text:escape_line(B)), $\\s, Hex(erx_procfs_core:name(B)), $\\n]
           || <<$x, H/binary>> <- binary:split(In, <<"\\n">>, [global, trim_all]), B <- [binary:decode_hex(H)]],
    ok = file:write_file("out.txt", Out), halt(0).
  ERL
  DECODER_ANCHOR = 'function* units(bytes: Uint8Array): Generator<Unit> {'
  TEXT_DECODER = "function* units(bytes: Uint8Array): Generator<Unit> {\n  " \
                 "for (const character of new TextDecoder('utf-8').decode(bytes)) yield { point: character.codePointAt(0) ?? 0 };\n}\n" \
                 'function* tableUnits(bytes: Uint8Array): Generator<Unit> {'

  def corpus
    vectors = JSON.parse(File.read(File.join(ROOT, 'test/fixtures/line_escape_vectors.json'))).fetch('vectors')
    random = Random.new(1)
    noise = Array.new(3000) { random.bytes(random.rand(0..12)) }
    utf8 = Array.new(500) { Array.new(random.rand(1..6)) { random.rand(0..0x10ffff) }.reject { |point| point.between?(0xd800, 0xdfff) }.pack('U*').b }
    vectors.map { |vector| [vector.fetch('input')].pack('H*') } + noise + utf8 + [''.b]
  end

  def lines(inputs) = inputs.map { |bytes| "x#{bytes.unpack1('H*')}\n" }.join

  def erlang(inputs)
    Dir.mktmpdir('erx-web-text') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror',
                                       '-I', File.join(ROOT, 'build/gen/erlang/apps/erx/include'), '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output
      File.write(File.join(work, 'in.txt'), lines(inputs))
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', ERLANG, chdir: work, stdin_data: '')
      assert status.success?, output
      answers(File.read(File.join(work, 'out.txt')))
    end
  end

  def client(inputs, stage)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', *Erx::WebStage::NODE, 'test/text_cli.ts',
                                     chdir: stage, stdin_data: lines(inputs))
    assert status.success?, output
    answers(output)
  end

  # Each answer line as [escape, entry name], both as UTF-8 strings.
  def answers(text)
    text.lines.map { |line| line.split.map { |field| [field.delete_prefix('x')].pack('H*').force_encoding(Encoding::UTF_8) } }
  end

  def test_escape_and_entry_names_agree_three_ways
    inputs = corpus
    erlang_answers = erlang(inputs)
    client_answers = Erx::WebStage.with(root: ROOT) { |stage| client(inputs, stage) }
    assert_equal inputs.size, client_answers.size
    inputs.zip(erlang_answers, client_answers).each do |bytes, (erlang_line, erlang_name), (client_line, client_name)|
      assert_equal Erx::LineEscape.escape(bytes), erlang_line, "Ruby and Erlang differ on #{bytes.unpack1('H*')}"
      assert_equal erlang_line, client_line, "the client differs on #{bytes.unpack1('H*')}"
      assert_equal erlang_name, client_name, "the client's /proc name differs on #{bytes.unpack1('H*')}"
    end
  end

  def test_a_client_decoding_with_text_decoder_fails_on_c0
    Erx::WebStage.with(root: ROOT) do |stage|
      path = File.join(stage, 'src/text.ts')
      source = File.read(path)
      assert_includes source, DECODER_ANCHOR
      assert_equal [['<0xC0>', '%C0']], client(["\xC0".b], stage)
      File.write(path, source.sub(DECODER_ANCHOR) { TEXT_DECODER })
      refute_equal '<0xC0>', client(["\xC0".b], stage).first.first
    end
  end
end
