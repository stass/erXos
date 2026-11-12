# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints'
require_relative 'core_archive'
require_relative 'declaration_files'
require_relative 'generated_abi'

module Erx
  # The chokepoint rules M1 binds, as data (docs/design-kernel.md,
  # "Chokepoint checks"; docs/design-stopgap.md, "Interfaces" and
  # "Verification and testing"). `make check` evaluates every rule over the
  # checkout's listed files; each active rule's seed is the violation its
  # host test feeds it. A rule whose sites are not in the tree yet is
  # Pending, and fails the check as soon as a file it awaits appears.
  #
  # Most are text checks over the C view of each source. The rules read
  # from the cores' call graph and from their syntax trees run in the stack
  # proof, which compiles the cores. The design's evidence read from
  # liberx's objects and the linked kernel is the object leg, pending until
  # the target objects it reads are built.
  #
  # The rules live in one file per group, chokepoint_rules/NAME.rb, loaded in
  # sorted order: each core's own, named after its source, and those of no
  # one core (stopgap_seam, other_checks). This file holds
  # what they share and the rules derived across them; the groups load at
  # GROUPS below, so a group file may use what stands above that line and
  # nothing below it. A core's group needs no entry here, and every core must
  # have one: a core source (CoreArchive::CORE_PATTERNS) without a group,
  # because the file was deleted or misnamed or never written, stops the load.
  # A core with nothing to police says so, with the reason, in a group of its
  # own.
  module ChokepointRules
    # The glue: erXos's C++ inside the stopgap kernel's tree.
    GLUE = 'fiasco/kernel/src/erx/**/*'
    FIASCO_BACKEND = 'liberx/backend/fiasco/**/*'
    # erXos's own C-family sources and the glue.
    ERXOS_C = Chokepoints::Scope.new(own: true, extra: [GLUE])
    STOPGAP = 'docs/design-stopgap.md'
    KERNEL = 'docs/design-kernel.md'
    # The pipe's files (docs/design-pipes.md, "The ring"): its checks and
    # steps (liberx/erx_pipe_*.c) and their header, a program's pipe ends in
    # liberx's program layer, and the session's pipe NIF. A pipe lane is the
    # lane layout, so they may name the lane's ring header and record (the
    # lane group); they never name the frame kind, and read a pipe's pages
    # only through erx_shm_copy (the pipe group).
    PIPE_NIF = 'otp/erts/emulator/nifs/erxos/erx_pipe_nif.c'
    PIPE_FILES = ['liberx/erx_pipe*', 'include/erx/pipe.h', 'liberx/program/pipe*', PIPE_NIF].freeze
    INCLUDE = Chokepoints::INCLUDE_PREFIX

    # An include of the header at path by any path ending in its file name,
    # in any case, as a case-insensitive file system resolves it.
    def self.include_of(path) = %r{#{INCLUDE}[<"](?:[^>"]*/)?#{Regexp.escape(File.basename(path))}[>"]}i

    # A use of a record's tag that is not one of the forms that only refer
    # to the record: a pointer or reference (*, &), the end of a
    # declaration or argument (; , )), or a declarator named after it
    # (typedef struct erx_budget erx_budget_t;). Every definition puts
    # something else after the tag (a brace, a base clause, final, an
    # attribute) or a line break, so any spelling of one is refused,
    # including those through a macro, and a declaration split after the
    # tag is refused too, on the safe side. A tag a macro pastes together
    # (erx_ ## budget) gets past it.
    def self.record_use(*tags)
      /\b(?:#{tags.map { |tag| Regexp.escape(tag) }.join('|')})\b(?!\s*(?:[*&;),]|[A-Za-z_]\w*\s*[;,)]))/
    end

    # The host tests of a core's source, which alone besides the core see
    # its private records: the drivers named after it in test/fixtures, its
    # CBMC harnesses in test/cbmc and its fuzzer. None of these trees is
    # built into the kernel or any image, and a test of the core is named
    # after it, so a new one needs no new entry.
    def self.host_tests(source)
      stem = File.basename(source, '.c')
      ["test/fixtures/#{stem}_*.c", "test/cbmc/#{stem}_*.c", "tools/fuzz/#{stem}_fuzz.c"].freeze
    end

    # What one group file declares. private_headers are its core's
    # hand-written private headers, which must exist; private_header_tests
    # are the host tests core-records-private lets include them and no other
    # core's. unchecked_objects are its liberx sources that object-leg does
    # not read yet. none is the stated reason a core has no rule of its own.
    Group = Data.define(:rules, :private_headers, :private_header_tests, :unchecked_objects, :none)
    RULE_KINDS = [Chokepoints::Forbidden, Chokepoints::IncludeForm, Chokepoints::Callers,
                  Chokepoints::Elsewhere, Chokepoints::Pending, Chokepoints::Writers].freeze
    GROUP_FILES = DeclarationFiles.new('chokepoint rules')
    private_constant :GROUP_FILES

    # Each file under chokepoint_rules/ calls this exactly once. A group
    # declares rules or the reason it has none, so an empty declaration, a
    # slip that would drop a core's rules without a word, cannot load.
    def self.declare_group(rules: [], private_headers: [], private_header_tests: [], unchecked_objects: [], none: nil)
      unless rules.empty? ? !none.to_s.strip.empty? : none.nil?
        raise Error, 'chokepoint rules: a group declares rules, or none: with the reason it has none'
      end
      stray = rules.reject { |rule| RULE_KINDS.any? { |kind| rule.is_a?(kind) } }
      raise Error, "chokepoint rules: not a rule: #{stray.first.inspect}" unless stray.empty?

      GROUP_FILES.declare(Group.new(rules: rules.freeze, private_headers: private_headers.freeze,
                                    private_header_tests: private_header_tests.freeze,
                                    unchecked_objects: unchecked_objects.freeze, none: none))
    end

    # Loads the group files in directory. Public so the tests can feed it
    # malformed files.
    def self.load_groups(directory) = GROUP_FILES.load_all(directory)

    # A core's group is named after its source. Raises on a core with no
    # group, whatever the cause.
    def self.require_core_groups(core_sources, group_names)
      missing = core_sources.reject { |source| group_names.include?(File.basename(source, '.c')) }
      return if missing.empty?

      groups = missing.map { |source| "tools/lib/erx/chokepoint_rules/#{File.basename(source, '.c')}.rb" }
      raise Error, "chokepoint rules: #{missing.join(', ')} has no group: add #{groups.join(', ')}, " \
                   'declaring its rules, or none: with the reason'
    end

    # The layouts the ABI file marks private, each with its owner. Their
    # records, offsets and accessors are only in their generated headers;
    # include/erx/abi.h declares only each one's tag, size and alignment.
    PRIVATE_LAYOUTS = ABI::Generated::SCHEMA.type_order
                                            .map { |name| ABI::Generated::SCHEMA.types.fetch(name) }
                                            .select { |type| type.is_a?(ABI::Layout) && type.private? }.freeze

    REPOSITORY = File.expand_path('../../..', __dir__)
    GROUPS = load_groups(File.join(__dir__, 'chokepoint_rules'))
    require_core_groups(CoreArchive.core_files(REPOSITORY), GROUPS.keys)

    # Each private layout's owner's host tests, each allowed to include
    # that layout's generated header.
    PRIVATE_LAYOUT_TEST_SITES = PRIVATE_LAYOUTS.flat_map do |layout|
      host_tests(layout.private_owner).map do |test|
        Chokepoints::Site.new(glob: test, permits: include_of(layout.private_header))
      end
    end.freeze

    # The cores' private headers among paths: every header named *_impl.h,
    # in any case, anywhere below kernel/ (a core's hand-written header in
    # kernel/core, kernel/sched or any later core directory, and each
    # private layout's generated header in kernel/generated), except in an
    # import, a directory below kernel/ with an ORIGIN.md. An import's own
    # header of the same suffix (kernel/crypto/blake3/blake3_impl.h) is
    # not one of them.
    def self.private_headers(paths)
      imports = paths.filter_map { |path| "#{File.dirname(path)}/" if File.basename(path) == 'ORIGIN.md' }
      paths.select { |path| File.fnmatch?('kernel/**/*_impl.h', path, File::FNM_PATHNAME | File::FNM_CASEFOLD) }
           .reject { |path| imports.any? { |import| path.start_with?(import) } }
    end

    # The private headers of this checkout, read once at load so a new one
    # is covered without an entry here, with each private layout's header
    # named even before it is generated. The checks run on this checkout,
    # so the set is the checked tree's. A header a group declares that the
    # glob does not find is a moved or deleted header, or a wrong root.
    PRIVATE_HEADERS = (private_headers(Dir.glob('kernel/**/*', base: REPOSITORY)) |
                       PRIVATE_LAYOUTS.map(&:private_header)).sort.freeze
    GROUPS.values.flat_map(&:private_headers).each do |header|
      raise Error, "#{header} is not below #{REPOSITORY}/kernel" unless PRIVATE_HEADERS.include?(header)
    end

    # An include of any of them, by any path ending in its file name, in
    # any case.
    PRIVATE_HEADER_INCLUDE = Regexp.union(PRIVATE_HEADERS.map { |header| include_of(header) })

    # A private layout's rule, built from the ABI file: only the layout's
    # owner and the owner's host tests include its generated header, and no
    # other file names its record's tag but to refer to it. Everywhere else
    # the layout is an incomplete type, so a member, an offset or an
    # accessor of it does not compile, and this rule keeps it so. It reads
    # the stopgap kernel's tree, glue and inherited sources alike. Its seed
    # is built from the layout too: includes from other files, by other
    # paths and in other cases, and definitions of the record in each form,
    # the owner's included.
    def self.private_layout_rule(layout)
      header = layout.private_header
      owner = layout.private_owner
      tag = layout.name
      name = File.basename(header, '_impl.h')
      includers = [owner, *host_tests(owner)].map { |glob| Chokepoints::Site.new(glob: glob, permits: include_of(header)) }
      definition = Chokepoints::Site.new(glob: header, permits: record_use(tag))
      Chokepoints::Forbidden.new(
        name: "#{name.tr('_', '-')}-private",
        rule: "only #{owner}, which the ABI file names as the owner of #{tag}, and its host tests include " \
              "#{header}, and no other file names struct #{tag} but to refer to it",
        design: 'docs/design-abi.md#source-grammar',
        scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
        pattern: Regexp.union(include_of(header), record_use(tag)),
        sites: [*includers, definition],
        seed: { 'kernel/core/seeded_core.c' => "#include \"#{File.basename(header)}\"\n",
                'liberx/seeded.c' => "#include \"#{header}\"\n",
                'fiasco/kernel/src/erx/seeded.cpp' => "#include <#{File.basename(header).upcase}>\n",
                'test/fixtures/seeded_driver.c' => "#include \"#{File.basename(header)}\"\n",
                'kernel/core/seeded_split.c' => "struct #{tag}\n{\n\tint member;\n};\n",
                'kernel/core/seeded_macro.c' => "#define R #{tag}\nstruct R { int member; };\n",
                'fiasco/kernel/src/kern/seeded.cpp' => "struct alignas(64) #{tag} final { };\n",
                owner => "union #{tag} { int member; };\n" }
      )
    end

    # A private layout's writers, built from the ABI file: only its owner and
    # the generated accessors in its header write any of its members, and no
    # other code casts a pointer to it, so not even a store at an offset
    # copied by hand from the header reaches a field. The header is read
    # where the build generates it.
    def self.private_layout_writers(layout)
      owner = layout.private_owner
      tag = layout.name
      header = "build/gen/#{layout.private_header}"
      Chokepoints::Writers.new(
        name: "#{File.basename(header, '_impl.h').tr('_', '-')}-writers",
        rule: "only #{owner} and the accessors of #{header} write struct #{tag} or cast a pointer to it",
        design: "#{KERNEL}#chokepoint-checks",
        record: tag,
        sites: [Chokepoints::WriterSite.new(glob: owner), Chokepoints::WriterSite.new(glob: header)],
        seed: { 'kernel/core/attach.c' => "struct #{tag} { unsigned word; };\n" \
                                          "void f(struct #{tag} *s) { *(unsigned *)((char *)s + 0) = 0; }\n" }
      )
    end

    # The rules derived across the groups, so that no group's file or list
    # names another's. Each private header is kept to the cores and the host
    # tests its own group declares, a site that permits that group's headers
    # alone.
    CORE_RECORDS_PRIVATE = Chokepoints::Forbidden.new(
      name: 'core-records-private',
      rule: "the cores' private headers (each *_impl.h below kernel/ outside an import: a core's own, " \
            'and each private ABI layout\'s generated header) are included only by the cores (B4), ' \
            'and each by its own core\'s host tests',
      design: "#{STOPGAP}#invariants",
      scope: ERXOS_C,
      pattern: PRIVATE_HEADER_INCLUDE,
      sites: [Chokepoints::Site.new(glob: 'kernel/core/*'),
              # A core outside kernel/core includes only its own group's private headers.
              *CoreArchive.core_files(REPOSITORY).reject { |source| source.start_with?('kernel/core/') }.map do |source|
                headers = GROUPS.fetch(File.basename(source, '.c')).private_headers
                permits = Regexp.union(headers.map { |header| include_of(header) })
                Chokepoints::Site.new(glob: source, permits: permits)
              end,
              *GROUPS.values.flat_map do |group|
                permits = Regexp.union(group.private_headers.map { |header| include_of(header) })
                group.private_header_tests.map { |test| Chokepoints::Site.new(glob: test, permits: permits) }
              end,
              *PRIVATE_LAYOUT_TEST_SITES],
      seed: { 'fiasco/kernel/src/erx/seeded.cpp' => "#include \"kernel/core/cap_impl.h\"\n",
              'liberx/seeded.c' => "#import \"kernel/core/cap_IMPL.h\"\n" }
    )

    # A new liberx source is a site of this rule, and its group declares it.
    OBJECT_LEG = Chokepoints::Pending.new(
      name: 'object-leg', rule: 'the text rules above also hold in the target objects: no object outside ' \
                                "liberx's fiasco backend references an l4_ symbol or holds a trap but the ABI's",
      design: "#{KERNEL}#chokepoint-checks",
      awaits: ['liberx/**/*'],
      existing: GROUPS.values.flat_map(&:unchecked_objects).sort.freeze,
      reason: "reads liberx's target objects, which no build produces yet"
    )

    # Every rule, whichever file declared it. The kinds are read from the
    # rules, so a rule can land in no wrong list.
    ALL = [*GROUPS.values.flat_map(&:rules), CORE_RECORDS_PRIVATE, OBJECT_LEG,
           *PRIVATE_LAYOUTS.map { |layout| private_layout_rule(layout) },
           *PRIVATE_LAYOUTS.map { |layout| private_layout_writers(layout) }].freeze
    # Rules read from each file's text.
    ACTIVE = ALL.grep(Chokepoints::Forbidden).concat(ALL.grep(Chokepoints::IncludeForm)).freeze
    # Rules read from the cores' call graph, which the stack proof builds at
    # every level it proves and checks against these before proving it.
    CALL_GRAPH = ALL.grep(Chokepoints::Callers).freeze
    # Rules read from the cores' syntax trees, which the stack proof dumps
    # and checks against these before proving the first level.
    SYNTAX_TREE = ALL.grep(Chokepoints::Writers).freeze
    # Rules other checks enforce, each with the test that seeds its violation.
    ELSEWHERE = ALL.grep(Chokepoints::Elsewhere).freeze
    # M1's rules whose sites are not in the tree. Each awaits the scope it
    # will police, either the files the design names as its first sites or
    # a whole directory less the files already there, which it lists; a new
    # file in that scope fails the check until the rule is implemented and
    # moved to an active kind.
    PENDING = ALL.grep(Chokepoints::Pending).freeze
  end
end
