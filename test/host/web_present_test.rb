# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/web_stage'

# The client's erx: encoder and presentation path table against erx_present
# (docs/design-web.md, "Verification and testing", the encodings and
# presentation paths row): over test/erlang/erx_web_present_corpus.erl's
# values of every presentation, the link the client writes from a canonical
# text is erx_present:uri/2's, and the path web/src/names.ts's
# presentationPath reads from it is erx_present:path/2's as /proc names.
# Erlang runs on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies). Then an erxText that keeps "%" must disagree: the canonical
# text's %2E is escaped again in the link, so no link holds a dot segment.
class WebPresentTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/generated/erx_schema.erl
               build/gen/erlang/apps/erx/src/generated/erx_present.erl
               erlang/apps/erx_files/src/erx_procfs_core.erl
               test/erlang/erx_web_present_corpus.erl].map { |path| File.join(ROOT, path) }.freeze
  # web.txt's web_segment_max: a longer entry name has no route (TODO.md).
  SEGMENT_MAX = 256
  ERX_KEPT = 'const ERX_KEPT = /[A-Za-z0-9_+,:=@./-]/;'

  Value = Data.define(:type, :text, :link, :path)

  def corpus
    Dir.mktmpdir('erx-web-present') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror',
                                       '-I', File.join(ROOT, 'build/gen/erlang/apps/erx/include'), '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-s', 'erx_web_present_corpus', 'run', chdir: work, stdin_data: '')
      assert status.success?, output
      File.read(File.join(work, 'out.txt')).lines.map do |line|
        type, *fields = line.split
        Value.new(type, *fields.map { |field| unhex(field) })
      end
    end
  end

  # Each value's [link, path, href] as the client writes them, the path nil
  # for a text that names nothing and the href nil for a value with no route.
  def client(values, stage)
    input = values.map { |value| "#{value.type} x#{value.text.unpack1('H*')}\n" }.join
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', *Erx::WebStage::NODE, 'test/present_cli.ts',
                                     chdir: stage, stdin_data: input)
    assert status.success?, output
    output.lines.map { |line| line.split.map { |field| field == '-' ? nil : unhex(field) } }
  end

  def unhex(field) = [field.delete_prefix('x')].pack('H*')

  def test_links_and_paths_agree_with_erx_present
    values = corpus
    assert_equal %w[budget domain group module pid], values.map(&:type).uniq.sort
    assert values.any? { |value| value.text.include?('%2E') }, 'no text segment escapes a dot'
    answers = Erx::WebStage.with(root: ROOT) { |stage| client(values, stage) }
    assert_equal values.size, answers.size
    values.zip(answers).each do |value, (link, path, href)|
      routable = value.text.split('/').all? { |part| part.bytesize <= SEGMENT_MAX }
      assert_equal(routable ? value.link.sub(/\Aerx:/, '/') : nil, href,
                   "the browser's link differs from the terminal's for #{value.type} #{value.text}")
      assert_equal value.link, link, "the client's link differs for #{value.type} #{value.text}"
      assert_equal value.path, path, "the client's path differs for #{value.type} #{value.text}"
    end
  end

  def test_texts_that_name_nothing_have_no_path
    Erx::WebStage.with(root: ROOT) do |stage|
      texts = [%w[pid 0.1.2], %w[proc 0.1.2], %w[module 7], %w[module 7/], %w[domain 1/2]]
      values = texts.map { |type, text| Value.new(type, text, nil, nil) }
      assert_equal [['erx:pid/0.1.2', 'processes/0.1.2']] + [nil] * 4,
                   client(values, stage).each_with_index.map { |(link, path), index| index.zero? ? [link, path] : path }
    end
  end

  def test_an_encoder_keeping_percent_disagrees
    values = corpus.select { |value| value.text.include?('%') }.first(1)
    Erx::WebStage.with(root: ROOT) do |stage|
      path = File.join(stage, 'src/names.ts')
      source = File.read(path)
      assert_includes source, ERX_KEPT
      File.write(path, source.sub(ERX_KEPT, 'const ERX_KEPT = /[A-Za-z0-9_+,:=@.\/%-]/;'))
      refute_equal values.first.link, client(values, stage).first.first
    end
  end
end
