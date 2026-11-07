# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_hostlink_9p_exhaustive.erl, which enumerates every interleaving of a
# host and a grant around the host link's 9P bridge core over a small bound, on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies) with the generated codec and
# grammar checked into the tree. The core as it is must pass; each seeded fault, a copy of the core
# with one rule broken, must fail with the property it breaks, which shows the enumeration
# reaches that property's failure (docs/design-live.md, "Files between the host and the
# machine").
class ErxHostlink9pExhaustiveTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[otp/erts/preloaded/src/erx_9p_grammar.erl erlang/apps/erx/src/generated/erx_9p.erl]
            .map { |source| File.join(ROOT, source) }.freeze
  CORE = File.join(ROOT, 'erlang/apps/erx_hostlink/src/erx_hostlink_9p.erl')
  TARGET = File.join(ROOT, 'test/erlang/erx_hostlink_9p_exhaustive.erl')
  DEADLINE_SECONDS = '600'

  # Each fault: the property it must break, as the failures that report it, the text of the
  # core it replaces and the replacement.
  Fault = Data.define(:property, :text, :broken)
  FAULTS = {
    # (a) A flush answered from its chain stays in the table, so it is answered again.
    answered_twice: Fault.new(property: /tag_not_in_use/,
                              text: "B1 = B#bridge{slots = maps:remove(Tag, Slots)},\n    {B2, More} = answer_head(Rest, B1),",
                              broken: "B1 = B,\n    {B2, More} = answer_head(Rest, B1),"),
    # (b) A chain whose request is answered is never answered itself.
    never_answered: Fault.new(property: /unanswered/,
                              text: "settle_chain(none, Chain, B) ->\n    answer_head(Chain, B).",
                              broken: "settle_chain(none, _Chain, B) ->\n    {B, []}."),
    # (c) Each flush takes a place before the earlier ones of its chain, a flush of a flush
    # before the flush it names.
    out_of_order: Fault.new(property: /flush_out_of_order|flush_before_its_target/,
                            text: 'seq = Seq + 1}, []}',
                            broken: 'seq = Seq - 1}, []}'),
    # (d) A forwarded request keeps no room for its flush.
    no_flush_room: Fault.new(property: /out_of_bounds/,
                             text: 'added_load({forward, _, _}, _B) -> 2;',
                             broken: 'added_load({forward, _, _}, _B) -> 1;'),
    # (e) A version keeps the flushes no grant holds, so their answers still reach the host.
    version_leaks: Fault.new(property: /old_tag_answered/,
                             text: "forgotten(_Tag, #flush{}, _B, Acc) ->\n    Acc.",
                             broken: "forgotten(Tag, #flush{} = Flush, _B, {Drains, Sends}) ->\n    " \
                                     '{Drains#{Tag => Flush}, Sends}.'),
    # (c) A flush the grant refuses or answers malformed abandons its request, so the host
    # takes a request as not done that its grant still does.
    refusal_abandons: Fault.new(property: /abandoned_without_grant/,
                                text: '{ok, {OldTag, Request}} -> abandoned(OldTag, Request, B1);',
                                broken: '{_, {OldTag, Request}} -> abandoned(OldTag, Request, B1);')
  }.freeze

  def test_every_interleaving_keeps_the_bridges_promises
    output, status = enumerate(File.binread(CORE))
    assert status.success?, output
    assert_equal 3, output.scan(/^exhaustive: .* traces, \d+ steps ok$/).size, output
  end

  FAULTS.each do |name, fault|
    define_method("test_the_enumeration_catches_#{name}") do
      source = File.binread(CORE)
      assert_includes source, fault.text
      output, status = enumerate(source.sub(fault.text, fault.broken))
      refute status.success?, "a bridge with #{name} passed:\n#{output}"
      assert_match fault.property, output
    end
  end

  private

  def enumerate(core_text)
    Dir.mktmpdir('erx-hostlink-9p-exhaustive') do |work|
      core = File.join(work, 'erx_hostlink_9p.erl')
      File.binwrite(core, core_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', File.join(ROOT, 'erlang/apps/erx/include'),
                                       '-o', work, *SOURCES, core, TARGET, stdin_data: '')
      assert status.success?, output
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_hostlink_9p_exhaustive', 'run', '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end
