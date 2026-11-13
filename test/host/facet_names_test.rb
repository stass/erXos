# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'set'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/facet_names'

# The table of cross-domain facets, abi/services and the system manifest, and the
# check that every facet name the Erlang sources use is in it (docs/design.md,
# "Chokepoint checks"): the tree passes, and each seeded violation fails with its
# file and line.
class FacetNamesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULE = 'erlang/apps/erx_seeded/src/seeded.erl'
  INTERFACE = 'abi/services/seeded.txt'
  MANIFEST = 'config/manifest/seeded.txt'
  DOC = 'docs/design-seeded.md'
  # Every exempt name used once in each of its listed files, so a seed reports only its
  # own violation.
  EXEMPT = Erx::FacetNames::UNDECLARED.each_with_object({}) do |(name, exemption), files|
    exemption.sites.each { |site| files[site] = "#{files[site]}x() -> erx:cap(#{name}).\n" }
  end.freeze

  def tree
    paths = IO.popen(['git', '-C', ROOT, 'ls-files'], &:read).split("\n")
    read = ->(selected) { selected.to_h { |path| [path, File.binread(File.join(ROOT, path))] } }
    [read.call(paths.select { |path| Erx::FacetNames.covers?(path) || Erx::FacetNames.table_file?(path) }),
     read.call(paths.select { |path| Erx::FacetNames.design_doc?(path) })]
  end

  # A small table: one interface citing one heading, one service of it and its facet.
  def table(interface: "# The seeded interface (#{DOC}, \"The `seeded` service\").\nservice seeded 9\n",
            manifest: "service seeded\n  server @domain.a\n  interface seeded\nfacet seeded\n  grantee system\n" \
                      "  service @service.seeded\n")
    [{ INTERFACE => interface, MANIFEST => manifest }, { DOC => "# Seeded\n\n## The `seeded` service\n" }]
  end

  def found(source, **table_text)
    files, docs = table(**table_text)
    files = files.merge(EXEMPT).merge(MODULE => source)
    Erx::FacetNames.violations(files, docs: docs).map { |violation| [violation.path, violation.line] }
  end

  def test_the_tree_passes_and_its_table_holds_every_manifest_facet
    files, docs = tree
    assert_empty Erx::FacetNames.violations(files, docs: docs).map(&:to_s)
    facets = Erx::FacetNames.table(files).first.facets.to_set { |facet| [facet.name, facet.interface] }
    assert_operator facets, :superset?, Set[%w[data files], %w[storage_ctl driver_control], %w[net net],
                                            %w[network_ctl driver_control], %w[web web],
                                            %w[inspect inspect]]
  end

  # inspect is a manifest service of a declared interface that cites its design section,
  # so its uses need no exemption.
  def test_inspect_resolves_to_its_interface_and_citation
    files, = tree
    interface = Erx::FacetNames.table(files).first.interfaces.find { |item| item.name == 'inspect' }
    assert_equal 'abi/services/inspect.txt', interface.path
    assert_match(/design-live\.md.*The inspect service/, interface.design.to_s)
    refute Erx::FacetNames::UNDECLARED.key?('inspect')
  end

  # The design's seed: a facet the table does not list, looked up by a domain.
  def test_an_unlisted_facet_fails_at_its_file_and_line
    assert_equal [[MODULE, 2]], found("f() -> erx:cap(seeded).\ng() -> erx:cap(rogue).\n")
  end

  def test_every_shape_of_a_use_is_read
    source = <<~'ERL'
      -erx_needs([seeded, rogue]).
      a(C) -> erx_cmd:facet(C, rogue).
      b() -> maps:find(rogue, erx:caps()).
      c() -> #{seeded := S, rogue := R} = erx:caps().
      d(T, G, L) -> {erx_facet_mint, T, rogue, G, L}.
      e() -> maps:get(rogue, erx:caps()).
      f() -> erx_facet:provide(rogue, self()).
      g(U) -> erx_driver_ctl:start_mint(rogue, U).
      h(U) -> {erx_driver_ctl, start_mint, [rogue, U]}.
      i(S, M) -> erx_driver_ctl:mint_request(S, rogue, M).
      j() -> erx_ns:mount({facet, rogue}, <<"/r">>, []).
    ERL
    assert_equal (1..11).map { |line| [MODULE, line] }, found(source)
  end

  # A create spec that hands a domain a facet by a name the table does not list, and a
  # session's start, whose keys are facets but for display and default_display, which name
  # services: console is exempt only in its listed files.
  def test_a_grant_in_a_create_spec_is_read
    source = <<~'ERL'
      f(P, C) -> erx_domain:start_session(P, #{console => C, display => rogue}).
      g(S) -> erx_domain:create(S#{facets => #{rogue => x}}).
      h(P) -> erx_domain:start_session(P, #{default_display => rogue}).
      i(P) -> erx_domain:start_session(P, #{rogue => {self(), #{}}}).
    ERL
    assert_equal [[MODULE, 1], [MODULE, 2], [MODULE, 4]], found(source)
  end

  # An interface's name is no facet: only a manifest service grants one.
  def test_an_interface_no_service_instantiates_is_no_facet
    assert_equal [[MODULE, 1]], found("f() -> erx:cap(other).\n",
                                      interface: "# (#{DOC}, \"The `seeded` service\").\nservice seeded 9\n" \
                                                 "service other 10\n")
  end

  def test_an_exempt_name_outside_its_listed_files_fails
    assert_equal [[MODULE, 1]], found("f() -> erx:cap(log).\n")
  end

  def test_a_comment_or_a_string_is_no_use
    assert_empty found("%% erx:cap(rogue)\nf() -> \"erx:cap(rogue)\".\n-doc \"\"\"\nerx:cap(rogue)\n\"\"\".\n")
  end

  def test_a_service_of_an_undeclared_interface_fails
    manifest = "service seeded\n  server @domain.a\n  interface 1\n"
    assert_equal [[MANIFEST, 1]], found('', manifest: manifest)
    assert_empty found('', manifest: manifest.sub('interface 1', 'interface 9'))
  end

  def test_an_interface_without_a_design_section_fails
    assert_equal [[INTERFACE, 2]], found('', interface: "# No citation.\nservice seeded 9\n")
    assert_equal [[INTERFACE, 2]], found('', interface: "# (#{DOC}, \"Missing\").\nservice seeded 9\n")
  end

  def test_an_exemption_no_use_names_fails
    files, docs = table
    stale = Erx::FacetNames.violations(files, docs: docs).map { |violation| violation.detail[/facet (\S+)/, 1] }
    assert_equal Erx::FacetNames::UNDECLARED.flat_map { |name, exemption| [name] * exemption.sites.size }.sort, stale.sort
  end

  # The funnel's table, which the build generates: each manifest service's public name
  # and nothing else, so no exempt name travels into the running system as table data
  # (the funnel's one stopgap name is a literal of its own). A facet row's own name is
  # no service's.
  def test_the_generated_table_holds_only_the_manifest_names
    files, = table
    Dir.mktmpdir do |root|
      write(root, files.merge(MANIFEST => files.fetch(MANIFEST).sub("facet seeded\n", "facet seeded\n  name \"other\"\n")))
      plan = Erx::FacetNames.generation(root: root)
      header = plan.files.fetch(Erx::FacetNames::HEADER)
      assert_equal ["-define(ERX_FACET_NAMES, ['seeded'])."], header.lines(chomp: true).grep(/^-define\(ERX_/).grep_v(/_HRL,/)
      assert_equal({ 'abi/services/*.txt' => [INTERFACE], 'config/manifest/*.txt' => [MANIFEST] }, plan.globs)
    end
  end

  # The exemptions are a stopgap that only shrinks: the tree's list meets its bound, a
  # list with one name more is refused, and so is one with a name fewer until the bound
  # comes down with it.
  def test_the_exemptions_only_shrink
    exemptions = Erx::FacetNames::UNDECLARED
    detail = ->(list) { Erx::FacetNames.exemption_violations(list).map(&:to_s).join }
    assert_empty detail.call(exemptions)
    longer = exemptions.merge('rogue' => Erx::FacetNames::Exemption.new(todo: 'none', sites: []))
    assert_match(/UNDECLARED holds 3 names, not EXEMPTIONS_MAX \(2\): the exemptions only shrink/, detail.call(longer))
    assert_match(/UNDECLARED holds 1 names, not EXEMPTIONS_MAX \(2\): lower EXEMPTIONS_MAX/,
                 detail.call(exemptions.except('web_line')))
  end

  # A manifest name outside the atom syntax generates nothing, so a name cannot close the
  # header's quoted atom and add one of its own.
  def test_the_generated_table_refuses_a_name_that_breaks_its_quoting
    files, = table
    Dir.mktmpdir do |root|
      write(root, files.merge(MANIFEST => files.fetch(MANIFEST).sub("  interface seeded\n",
                                                                     "  interface seeded\n  name \"a',b\"\n")))
      assert_raises(Erx::Error) { Erx::FacetNames.generation(root: root) }
    end
  end

  # A table with a violation, here a service of an interface abi/services does not
  # declare, generates nothing.
  def test_the_generated_table_refuses_a_manifest_violation
    files, = table
    Dir.mktmpdir do |root|
      write(root, files.merge(INTERFACE => "service other 9\n"))
      error = assert_raises(Erx::Error) { Erx::FacetNames.generation(root: root) }
      assert_match "service seeded's interface seeded", error.message
    end
  end

  # A name the manifest declares while UNDECLARED still exempts it generates nothing, so
  # no exemption outlives its declaration.
  def test_the_generated_table_refuses_a_declared_exempt_name
    files, = table
    Dir.mktmpdir do |root|
      write(root, files.merge(MANIFEST => files.fetch(MANIFEST).sub("  interface seeded\n", "  interface seeded\n  name \"console\"\n")))
      error = assert_raises(Erx::Error) { Erx::FacetNames.generation(root: root) }
      assert_match 'both declared and exempt in UNDECLARED: console', error.message
    end
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      files, docs = table
      write(root, files.merge(docs).merge(MODULE => "f() -> erx:cap(rogue).\n"))
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_facet_names, [*files.keys, *docs.keys, MODULE]) }
      assert_match "#{MODULE}:1", error.message
    end
  end

  private

  # Each of files written under root at its path.
  def write(root, files)
    files.each do |path, text|
      FileUtils.mkdir_p(File.join(root, File.dirname(path)))
      File.write(File.join(root, path), text)
    end
  end
end
