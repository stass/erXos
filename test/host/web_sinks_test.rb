# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/web_sinks'

# The web client's sink and href chokepoints (docs/design-web.md,
# "Chokepoints"): the tree passes, each seeded sink and each href written
# other than by hrefOf fails, and what a comment or a regular expression says
# is not code.
class WebSinksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SEEDED = 'web/src/seeded.ts'
  VIEW = 'web/src/views/seeded.tsx'

  def lines_of(files) = Erx::WebSinks.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes
    paths = Erx::WebSinks::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    refute_empty paths
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::WebSinks.violations(files).map(&:to_s)
  end

  def test_each_sink_fails
    sinks = [
      'node.innerHTML = text;',
      'node.outerHTML = text;',
      "node.insertAdjacentHTML('beforeend', text);",
      'document.write(text);',
      'document . writeln(text);',
      "frame.setAttribute('srcdoc', text);",
      'range.createContextualFragment(text);',
      "new DOMParser().parseFromString(text, 'text/html');",
      'eval(text);',
      'const run = new Function(text);',
      "setTimeout('run()', 10);",
      'setInterval(`tick()`, 10);',
      "const link = 'JavaScript:alert(1)';",
      'const element = <div dangerouslySetInnerHTML={{ __html: text }} />;',
      'node.setHTMLUnsafe(text);',
      'Document.parseHTMLUnsafe(text);',
      "node.setAttribute('onclick', text);"
    ]
    assert_equal sinks.each_index.map { |index| [SEEDED, index + 1] }, lines_of(SEEDED => sinks.join("\n"))
  end

  def test_what_is_no_sink_passes
    text = <<~TS
      // node.innerHTML = text; eval(text)
      /* document.write(text);
         javascript: */
      const pattern = /[\\/]*/; const evaluation = 1;
      setTimeout(() => run(), 10);
      const type: Function | undefined = undefined;
      const message = `${count} // items`;
    TS
    assert_empty lines_of(SEEDED => text)
  end

  def test_a_navigation_goes_only_to_href_of
    text = <<~TS
      history.pushState(null, '', hrefOf(route));
      history.replaceState({ at: [1, 2] }, '', hrefOf(Route.path(names) ?? Route.home()));
      history.pushState(null, '', url);
      history.pushState(null, '', hrefOf(route) + '#x');
      location.assign(url);
      window.location.replace(hrefOf(route));
      window.open(url);
      location = url;
      window.location.href = url;
    TS
    assert_equal [3, 4, 5, 7, 8, 9].map { |line| [SEEDED, line] }, lines_of(SEEDED => text)
  end

  def test_a_comment_marker_inside_code_hides_nothing
    view = <<~'TSX'
      <p>see /proc/domains/*/status</p>
      node.innerHTML = text;
      <p>see http://example.com</p>; node.innerHTML = text;
      if (ok) /\/*/.test(s); node.innerHTML = text;
      /* never closed
      node.innerHTML = text;
    TSX
    assert_equal [2, 3, 4, 6].map { |line| [VIEW, line] }, lines_of(VIEW => view)
  end

  def test_code_after_a_regular_expression_or_template_is_still_read
    text = "const a = /\\/\\//; eval(a);\nconst b = `x${'}`'}`; eval(b);\nconst c = `${{ k: 1 }.k}`; eval(c);\n"
    assert_equal [[SEEDED, 1], [SEEDED, 2], [SEEDED, 3]], lines_of(SEEDED => text)
  end

  def test_only_an_href_of_call_writes_an_href
    view = <<~TSX
      <a href={hrefOf(route)}>{label}</a>
      <a href={hrefOf(Route.path(names) ?? Route.home())}>x</a>
      <a href="/proc/a">x</a>
      <a href={'/proc/' + name}>x</a>
      <a href={hrefOf(route) + '?x'}>x</a>
      <a {...{ href: target }}>x</a>
    TSX
    assert_equal [[VIEW, 3], [VIEW, 4], [VIEW, 5], [VIEW, 6]], lines_of(VIEW => view)
    module_text = "anchor.href = hrefOf(route);\nanchor.setAttribute('HREF', path);\n"
    assert_equal [[SEEDED, 1], [SEEDED, 2]], lines_of(SEEDED => module_text)
  end

  def test_generated_sources_and_tests_are_not_read
    refute Erx::WebSinks.covers?('web/src/generated/proto.ts')
    refute Erx::WebSinks.covers?('web/test/text.test.ts')
    assert Erx::WebSinks.covers?('web/src/views/record.tsx')
    assert Erx::WebSinks.covers?('web/src/legacy.js')
  end
end
