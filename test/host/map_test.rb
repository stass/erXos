# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/map_model'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges the mapping-record core (kernel/core/map.c) against MapModel, a sorted
# array of intervals that shares nothing with the tree. The driver runs command
# scripts through the core's public interface, checks the core's invariants and
# a stand-in for the reverse maps after each command, and prints every plan and
# the whole tree; the model predicts each line. Tests also state the expected
# results by hand, so the model's reading of the design is itself pinned.
#
# Bounds: every page-aligned range over pages 99 to 115 of a fixture of seven
# records, under each of seven range operations and three fixed inserts; each
# failing allocation at each of the first six parts of a call; every base and
# size of a placement over a sparse tree; RANDOM_SCRIPTS scripts of RANDOM_LENGTH
# commands over a small space and as many at the top of a 2^52-page space, and
# four long scripts over a larger tree; ERX_MAPPINGS_MAX records at the limit.
class MapTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_MAP_SEED', '20261103'))
  RANDOM_SCRIPTS = 400
  RANDOM_LENGTH = 60
  M = MapModel
  P = M::PAGE
  INIT = 'init 1024'

  # An insert command, a fixed reservation unless told otherwise. addr and size
  # give the bytes as a call would pass them, where page and pages do not.
  # ceiling gives rights and object_ceiling alike unless each is told; only an
  # object's mapping, deleted or not, takes them.
  def self.insert(page: 0, pages: 1, addr: page * P, size: pages * P, vm_flags: M::FIXED, base: 0, kind: M::RESERVED,
                  object: 0, offset: 0, object_pages: 0, prot: M::NONE, ceiling: 0, rights: ceiling,
                  object_ceiling: ceiling, flags: 0, mode: 'ok')
    "insert #{addr} #{size} #{vm_flags} #{base} #{kind} #{object} #{offset} #{object_pages} " \
      "#{prot} #{rights} #{object_ceiling} #{flags} #{mode}"
  end

  def self.reserve(page, pages, **options) = insert(page: page, pages: pages, **options)
  def self.placed(pages, base, **options) = insert(pages: pages, vm_flags: 0, base: base, **options)

  def self.object(page, pages, object: 1, offset: 0, prot: M::R, ceiling: M::RW, **options)
    insert(page: page, pages: pages, kind: M::OBJECT, object: object, offset: offset, object_pages: 4096, prot: prot,
           ceiling: ceiling, **options)
  end

  def self.kernel(page) = insert(page: page, kind: M::KERNEL, prot: M::RW)

  def self.part(operation, page, pages, object: 0, prot: 0, mode: 'ok', at: 0)
    "part #{operation} #{page * P} #{pages * P} #{object} #{prot} #{mode} #{at}"
  end

  def self.commit(page, pages, object: 2, **options) = part(M::COMMIT, page, pages, object: object, **options)
  def self.decommit(page, pages, **options) = part(M::DECOMMIT, page, pages, **options)
  def self.protect(page, pages, prot, object: 2, **options) = part(M::PROTECT, page, pages, object: object, prot: prot, **options)
  def self.release(page, pages, mode: 'ok') = "release #{page * P} #{pages * P} #{mode}"

  # Pages 100 to 115: a reservation, private memory, an object at an offset, a
  # hole, an object that does not line up with the first, a read-only private
  # run, and a reservation.
  FIXTURE = [reserve(100, 3), commit(100, 1), reserve(103, 2), commit(103, 2), object(105, 3, offset: 7),
             object(109, 2, offset: 7), reserve(111, 2), commit(111, 2), protect(111, 2, M::R), reserve(113, 3)].freeze
  WINDOW = (99..115).to_a.freeze
  RANGES = WINDOW.product(WINDOW).select { |low, high| low < high }.freeze

  # One plan as the driver prints it and the model predicts it.
  PlanLine = Struct.new(:nspares, :start, :stop, :next, :done, :charge) do
    def self.parse(line) = new(*line.split.drop(3).map(&:to_i))
  end

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-map-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported map-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver = (@driver ||= build_driver(File.join(@root, 'kernel/core/map.c'), name: 'map'))

  def test_every_range_under_every_operation
    operations = lambda do |low, pages|
      [self.class.release(low, pages), self.class.commit(low, pages), self.class.decommit(low, pages),
       self.class.protect(low, pages, M::R), self.class.protect(low, pages, M::RX),
       self.class.protect(low, pages, M::NONE), self.class.protect(low, pages, M::RW)]
    end
    scripts = RANGES.flat_map { |low, high| operations.call(low, high - low).map { |line| [INIT, *FIXTURE, line] } }
    assert_operator scripts.size, :>, 900
    assert_agrees(scripts)
  end

  def test_every_range_under_a_fixed_insert
    scripts = RANGES.flat_map do |low, high|
      pages = high - low
      [[INIT, *FIXTURE, self.class.reserve(low, pages)],
       [INIT, *FIXTURE, self.class.reserve(low, pages, vm_flags: M::FIXED | M::NOREPLACE)],
       [INIT, *FIXTURE, self.class.object(low, pages, object: 3, offset: 5, flags: 1)]]
    end
    assert_agrees(scripts)
  end

  # Allocation that fails: at every part of a call, and at every insert and
  # release, the tree is exactly what the parts before it left.
  def test_allocation_failure_changes_nothing
    scripts = %w[short drop].flat_map do |mode|
      [self.class.release(101, 1, mode: mode), self.class.reserve(101, 1, mode: mode),
       self.class.placed(1, 90, mode: mode),
       *6.times.flat_map do |at|
         [self.class.protect(100, 14, M::R, mode: mode, at: at), self.class.decommit(100, 14, mode: mode, at: at),
          self.class.commit(100, 14, mode: mode, at: at)]
       end].map { |line| [INIT, *FIXTURE, line] }
    end
    output = assert_agrees(scripts)
    assert_includes output, 'A dropped'
    assert_includes output, "A #{M::ENOMEM}"
  end

  # The highest hole below the base, whatever lies above it.
  def test_placement_takes_the_highest_hole_below_the_base
    script = [INIT, self.class.reserve(100, 2), self.class.reserve(110, 2), self.class.placed(4, 106),
              self.class.placed(1, 106), self.class.placed(1, 2000), self.class.placed(1, 16), self.class.placed(1000, 2000)]
    lines = assert_agrees([script])
    assert_equal [102, 99, 1023], lines.grep(/\AA 0 /).map { |line| line.split.last.to_i }.last(3)
    assert_equal ["= insert #{M::ENOMEM}"] * 2, lines.grep(/\A= insert -/)
  end

  # A hint that names a free, page-aligned range inside the user range is where
  # the record goes, above the base or below it; any other hint is ignored.
  def test_a_hint_is_honoured_when_free
    klass = self.class
    lines = assert_agrees([[INIT, klass.reserve(200, 4),
                            klass.placed(2, 500, addr: 300 * P), klass.placed(2, 100, addr: 600 * P),
                            klass.placed(2, 500, addr: 201 * P), klass.placed(2, 500, addr: 199 * P),
                            klass.placed(2, 500, addr: (300 * P) + 1), klass.placed(2, 500, addr: 1023 * P),
                            klass.placed(2, 500, addr: 8 * P), klass.placed(2, 500, addr: (1 << 64) - P),
                            klass.placed(2, 500, addr: (1 << 64) - 1)]])
    assert_equal [300, 600, 498, 496, 494, 492, 490, 488, 486],
                 lines.grep(/\AA 0 /).map { |line| line.split.last.to_i }.last(9)
  end

  # ERX_VM_NOREPLACE modifies ERX_VM_FIXED, and a hint does not change that.
  def test_noreplace_needs_fixed
    lines = assert_agrees([[INIT, self.class.placed(1, 500, addr: 300 * P, vm_flags: M::NOREPLACE)]])
    assert_includes lines, "= insert #{M::EINVAL}"
  end

  def test_every_placement_over_a_sparse_tree
    sparse = [[20, 1], [22, 2], [30, 1], [35, 5], [41, 1], [50, 2]].map { |page, pages| self.class.reserve(page, pages) }
    scripts = (16..60).to_a.product((1..12).to_a).map { |base, pages| ['init 64', *sparse, self.class.placed(pages, base)] }
    assert_agrees(scripts)
  end

  def test_boundary_arithmetic
    top = M::LIMIT
    wild = (1 << 64) - P
    releases = [[1, P], [P, 1], [P, 0], [M::LOW * P, P], [(M::LOW - 1) * P, P], [wild, P], [(top - 1) * P, P],
                [(top - 1) * P, 2 * P], [P, wild], [wild, wild]].map { |addr, size| "release #{addr} #{size} ok" }
    script = ["init #{top + 1}", "init #{M::LOW}", "init #{M::LOW + 1}", "init #{top}", *releases,
              self.class.reserve(top - 1, 1), "lookup #{top - 1}", self.class.commit(top - 1, 1),
              self.class.protect(top - 3, 1, M::R), "edges #{(top - 1) * P} #{P} #{top}",
              "edges #{(top - 1) * P} #{P} #{top + 1}", "edges #{(top - 1) * P} #{P} 0", self.class.placed(1, top + 5),
              self.class.placed(top - M::LOW, top), insert_of_size(wild, base: top),
              self.class.object(M::LOW, 1, offset: (1 << 64) - 1)]
    lines = assert_agrees([script])
    assert_equal ["= init #{M::EINVAL}", "= init #{M::EINVAL}", '= init 0', '= init 0'], lines.first(4)
    assert_equal [M::EINVAL, M::EINVAL, M::EINVAL], lines.grep(/\A= release/).first(3).map { |line| line.split[2].to_i }
    assert_includes lines, "= part #{M::ERANGE}"
  end

  def insert_of_size(size, base:) = self.class.insert(size: size, vm_flags: 0, base: base)

  # Requests no decode checked: the planners refuse them too.
  def test_planners_refuse_what_no_decode_checked
    start = 100
    lines = assert_agrees([[INIT, "rawrelease #{start} #{start}", "rawrelease #{start + 1} #{start}", 'rawrelease 1 20',
                            'rawrelease 1000 2000', "rawpart #{M::COMMIT} #{start} #{start} #{start}",
                            "rawpart #{M::COMMIT} #{start} #{start + 2} #{start + 3}",
                            "rawpart #{M::COMMIT} #{start} #{start + 2} #{start - 1}",
                            "rawpart 9 #{start} #{start + 2} #{start}", "rawpart 0 #{start} #{start + 2} #{start}"]])
    assert_equal ["= raw #{M::EINVAL}"] * 9, lines.grep(/\A= raw/)
  end

  REFUSED_INSERTS = {
    # Writable with executable is no protection at all, nor is write alone.
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::RW | M::RX, ceiling: M::RWX } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: 2, ceiling: M::RWX } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::RW, ceiling: M::R } => M::ERIGHTS,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::R, ceiling: 8 } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::R, rights: 0x101, object_ceiling: M::R } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: 0x101, ceiling: M::R } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::R, ceiling: M::R, flags: 0x101 } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::RW, rights: M::RW, object_ceiling: M::R } => M::ERIGHTS,
    { kind: M::OBJECT, object: 0, object_pages: 4096, prot: M::R, ceiling: M::R } => M::EINVAL,
    { kind: M::OBJECT, object: 1, object_pages: 4096, prot: M::R, ceiling: M::R, flags: 2 } => M::EINVAL,
    # A record past the object's end, and an offset past it that would wrap.
    { kind: M::OBJECT, object: 1, object_pages: 4096, offset: 4096, prot: M::R, ceiling: M::R } => M::ERANGE,
    { kind: M::OBJECT, object: 1, object_pages: 4096, offset: 5000, prot: M::R, ceiling: M::R } => M::ERANGE,
    { kind: M::RESERVED, prot: M::R } => M::EINVAL,
    { kind: M::RESERVED, ceiling: M::R } => M::EINVAL,
    { kind: M::RESERVED, object: 1 } => M::EINVAL,
    { kind: M::RESERVED, offset: 1 } => M::EINVAL,
    { kind: M::RESERVED, flags: 1 } => M::EINVAL,
    { kind: M::PRIVATE, object: 1, object_pages: 4096, prot: M::RX } => M::ERIGHTS,
    { kind: M::PRIVATE, object: 1, object_pages: 4096, prot: M::RW, ceiling: M::RWX } => M::EINVAL,
    { kind: M::PRIVATE, object: 0, object_pages: 4096, prot: M::RW } => M::EINVAL,
    { kind: M::PRIVATE, object: 1, offset: 3, prot: M::RW } => M::EINVAL,
    { kind: M::KERNEL, pages: 2, prot: M::RW } => M::EINVAL,
    { kind: M::KERNEL, prot: M::R } => M::EINVAL,
    { kind: M::KERNEL, prot: M::RW, flags: 1 } => M::EINVAL,
    { kind: M::KERNEL, prot: M::RW, ceiling: M::RW } => M::EINVAL,
    { kind: 0 } => M::EINVAL,
    { kind: 6 } => M::EINVAL,
    { vm_flags: M::NOREPLACE } => M::EINVAL,
    { vm_flags: 4 } => M::EINVAL
  }.freeze

  # K4 and no writable with executable: every refusal, before anything moves.
  def test_ceilings_and_write_with_execute
    REFUSED_INSERTS.each do |fields, status|
      lines = assert_agrees([[INIT, self.class.insert(page: 20, **fields)]])
      assert_includes lines, "= insert #{status}", fields.to_s
      assert_equal 'T 0', lines.last
    end

    # A read-only object takes no protect above its ceiling; RX over a
    # reservation is refused with nothing committed; a JIT object's ceiling
    # allows each of RW and RX and never both at once.
    script = [INIT, self.class.object(100, 4, ceiling: M::R), self.class.reserve(104, 4), self.class.protect(100, 4, M::RW),
              self.class.protect(104, 4, M::RX), self.class.protect(100, 4, M::RWX), self.class.protect(100, 4, 2),
              self.class.protect(100, 4, 6), self.class.object(110, 2, ceiling: M::RWX), self.class.protect(110, 2, M::RW),
              self.class.protect(110, 2, M::RX), self.class.protect(110, 2, M::R)]
    lines = assert_agrees([script])
    assert_equal [M::ERIGHTS, M::ERIGHTS, M::EINVAL, M::EINVAL, M::EINVAL],
                 lines.grep(/\A= part -/).map { |line| line.split[2].to_i }
  end

  # K5: a decommit trims only private memory, and exactly what the range maps;
  # it ends at a mapping of an object, the parts before it applied.
  def test_trimming_never_meets_sharing
    lines = assert_agrees([[INIT, self.class.reserve(100, 8), self.class.commit(100, 8), self.class.object(108, 4),
                            self.class.decommit(102, 8)]])
    assert_equal 'X 1 6 2 102', lines.grep(/\AX /).last
    assert_includes lines, "= part #{M::EEXIST}"
    assert_includes lines.last, "108,112,#{M::OBJECT},1,0"
    assert_includes lines.last, "102,108,#{M::RESERVED},0,0,0,3,0"
  end

  # Commit and decommit are private memory's calls: a mapping of an object,
  # deleted or not, ends them with ERX_EEXIST and no effect on it, the parts before
  # it applied. Protect stays the one call over mixed kinds.
  def test_commit_and_decommit_refuse_what_is_not_private
    klass = self.class
    start = [INIT, klass.reserve(100, 2), klass.commit(100, 2), klass.object(102, 2), klass.reserve(104, 2)]
    deleted = [*start, 'deleted 102']
    scripts = [[*start, klass.commit(100, 6)], [*start, klass.decommit(100, 6)],
               [*deleted, klass.commit(100, 6)], [*deleted, klass.decommit(100, 6)],
               [*start, klass.protect(100, 6, M::R)], [*deleted, klass.protect(100, 6, M::R)]]
    lines = assert_agrees(scripts)
    assert_equal 4, lines.grep(/\A= part #{M::EEXIST}\z/).size
    assert_includes lines, "T 3 100,102,#{M::RESERVED},0,0,0,3,0 102,104,#{M::OBJECT},1,0,#{M::R},#{M::RW},0 " \
                           "104,106,#{M::RESERVED},0,0,0,3,0"
    assert_includes lines, "T 3 100,102,#{M::PRIVATE},2,100,#{M::R},#{M::RW},0 102,104,#{M::DELETED},0,0,#{M::R},#{M::RW},0 " \
                           "104,106,#{M::PRIVATE},2,104,#{M::R},#{M::RW},0"
  end

  # An apply reports what its plan does to translations and pages, and nothing
  # for a plan it refuses: a replacing insert and a release drop translations
  # over any record but a reservation, a deleted one included, since it may hold
  # some while its deletion's table step runs; a protect drops them when it lowers
  # an access; a kernel-user page's teardown drops its.
  def test_effects_come_from_an_accepted_apply
    klass = self.class
    effects = lambda do |*commands|
      assert_agrees([[INIT, klass.reserve(100, 4), klass.commit(100, 2), *commands]]).grep(/\AX /)
    end
    assert_equal 'X 1 0 0 0', effects.call(klass.release(100, 1)).last
    assert_equal 'X 1 0 0 0', effects.call(klass.reserve(101, 2)).last
    assert_equal 'X 0 0 0 0', effects.call(klass.release(102, 2)).last
    assert_equal 'X 0 0 0 0', effects.call(klass.reserve(102, 2)).last
    assert_equal 'X 1 2 2 100', effects.call(klass.decommit(100, 2)).last
    assert_equal 'X 1 0 0 0', effects.call(klass.kernel(200), 'kremove 200 ok').last
    assert_equal 2, effects.call(klass.decommit(100, 1, mode: 'short')).size
    assert_equal 'X 1 0 0 0', effects.call(klass.object(200, 2), 'deleted 200', klass.release(200, 2)).last
    assert_equal 'X 1 0 0 0', effects.call(klass.protect(100, 2, M::R)).last
    assert_equal 'X 0 0 0 0', effects.call(klass.protect(100, 2, M::R), klass.protect(100, 2, M::RW)).last
  end

  # A plan's report is the caller's copy, so lowering nspares cannot make the
  # apply read a record it was not given.
  def test_an_apply_counts_its_own_spares
    lines = assert_agrees([[INIT, self.class.reserve(100, 6), "lowspares #{102 * P} #{P}"]])
    assert_includes lines, "= lowspares #{M::ENOMEM}"
  end

  # What every planner refuses leaves nothing behind for a caller to act on; the
  # driver stops on a refused plan that reports anything.
  def test_a_refused_plan_reports_nothing
    klass = self.class
    start = [INIT, klass.reserve(100, 2), klass.commit(100, 1), klass.kernel(104), klass.object(105, 1, ceiling: M::R)]
    assert_agrees([[*start, klass.reserve(104, 1), klass.release(104, 1), klass.protect(105, 1, M::RW),
                    klass.reserve(104, 1, vm_flags: M::FIXED | M::NOREPLACE), klass.placed(2000, 2000), 'kremove 100 ok',
                    klass.commit(104, 1), klass.commit(101, 1, object: 0), klass.protect(101, 1, M::RX)]])
  end

  # A record's ceiling comes from the two facts that bound it, in one place.
  def test_a_ceiling_is_rights_and_the_object_ceiling
    klass = self.class
    lines = assert_agrees([[INIT, klass.object(100, 2, rights: M::RW, object_ceiling: M::R, prot: M::R),
                            klass.object(102, 2, rights: M::RX, object_ceiling: M::RW, prot: M::R),
                            klass.object(104, 2, rights: M::RWX, object_ceiling: M::RX, prot: M::RX),
                            klass.protect(100, 2, M::RW), klass.protect(102, 2, M::RX),
                            klass.insert(page: 110, kind: M::DELETED, prot: M::R, ceiling: M::R)]])
    assert_includes lines, "= part #{M::ERIGHTS}"
    assert_includes lines.last, "100,102,#{M::OBJECT},1,0,#{M::R},#{M::R},0"
    no_object = assert_agrees([[INIT, klass.reserve(100, 2), klass.protect(100, 2, M::RX, object: 0),
                                klass.protect(100, 2, M::R, object: 0)]])
    assert_equal [M::ERIGHTS, M::EINVAL], no_object.grep(/\A= part -/).map { |line| line.split[2].to_i }
    assert_includes lines.last, "102,104,#{M::OBJECT},1,0,#{M::R},#{M::R},0"
    assert_includes lines.last, "104,106,#{M::OBJECT},1,0,#{M::RX},#{M::RX},0"
    assert_includes lines.last, "110,111,#{M::DELETED},0,0,#{M::R},#{M::R},0"
  end

  # A protection wider than the record's field is refused, not narrowed.
  def test_a_wide_protection_is_refused
    lines = assert_agrees([[INIT, self.class.object(100, 2), self.class.part(M::PROTECT, 100, 2, prot: 0x103)]])
    assert_includes lines, "= part #{M::EINVAL}"
    assert_includes lines.last, "100,102,#{M::OBJECT},1,0,#{M::R}"
  end

  # K5 by construction: however a caller reuses one private object, each page
  # takes its own number as its offset, so two pages never share one, whether a
  # commit or an insert made the record.
  def test_a_private_offset_is_its_page
    klass = self.class
    lines = assert_agrees([[INIT, klass.reserve(100, 4), klass.commit(100, 2), klass.commit(102, 2),
                            klass.decommit(100, 2), klass.commit(100, 1),
                            klass.insert(page: 200, pages: 2, kind: M::PRIVATE, object: 2, prot: M::RW),
                            klass.insert(page: 300, pages: 2, kind: M::PRIVATE, object: 2, prot: M::RW, offset: 5)]])
    assert_includes lines.last, "100,101,#{M::PRIVATE},2,100"
    assert_includes lines.last, "102,104,#{M::PRIVATE},2,102"
    assert_includes lines.last, "200,202,#{M::PRIVATE},2,200"
    assert_includes lines, "= insert #{M::EINVAL}"
  end

  # A commit of 1 GiB is 4,096 parts of 64 pages that stay one record, and each
  # part after the first takes no spare.
  def test_a_large_commit_stays_one_record
    pages = 262_144
    lines = assert_agrees([['init 1048576', self.class.reserve(1024, pages), self.class.commit(1024, pages)]])
    parts = plans(lines)
    assert_equal 4096, parts.size
    assert_equal 1, parts.first.nspares
    assert_equal [0], parts.drop(1).map(&:nspares).uniq
    assert_equal [64], parts.map(&:charge).uniq
    assert lines.last.start_with?('T 1 ')
  end

  # Neighbours merge only when kind, object, offset, protection, ceiling and
  # flags line up, and a kernel-user or deleted record merges with nothing.
  def test_merges_line_up
    scripts = [
      [INIT, self.class.reserve(100, 4), self.class.commit(100, 2), self.class.commit(102, 2)],
      [INIT, self.class.reserve(100, 4), self.class.commit(100, 2, object: 2), self.class.commit(102, 2, object: 3)],
      [INIT, self.class.object(100, 4), self.class.object(104, 4, offset: 9), self.class.protect(100, 8, M::NONE)],
      [INIT, self.class.object(100, 4), self.class.object(104, 4, offset: 4, flags: 1), self.class.protect(100, 8, M::NONE)],
      [INIT, self.class.object(100, 4), self.class.object(104, 4, offset: 4, ceiling: M::R),
       self.class.protect(100, 8, M::NONE)],
      [INIT, self.class.object(100, 6), self.class.protect(102, 2, M::RW), self.class.protect(102, 2, M::R)],
      [INIT, self.class.object(100, 2), self.class.object(102, 2, offset: 2), 'deleted 100', 'deleted 102',
       self.class.protect(100, 4, M::NONE)],
      [INIT, self.class.reserve(100, 2), self.class.reserve(102, 2), self.class.protect(100, 4, M::NONE)],
      [INIT, self.class.reserve(100, 2), self.class.reserve(102, 2), self.class.reserve(104, 2), self.class.commit(102, 2),
       self.class.decommit(102, 2)]
    ]
    lines = assert_agrees(scripts)
    assert_includes lines, "T 1 100,106,#{M::OBJECT},1,0,#{M::R},#{M::RW},0"
    assert_includes lines, "T 3 100,102,#{M::RESERVED},0,0,0,3,0 102,104,#{M::RESERVED},0,0,0,3,0 " \
                           "104,106,#{M::RESERVED},0,0,0,3,0"
  end

  # A kernel-user page: every range call that overlaps it fails with
  # ERX_EEXIST, a release before anything moves, and only its own teardown
  # removes it.
  def test_kernel_user_pages
    fixture = [INIT, self.class.reserve(100, 4), self.class.kernel(104), self.class.reserve(105, 4)]
    scripts = [
      [*fixture, self.class.release(102, 4)], [*fixture, self.class.commit(102, 4)],
      [*fixture, self.class.decommit(102, 4)], [*fixture, self.class.protect(102, 4, M::RW)],
      [*fixture, self.class.protect(104, 1, M::NONE)], [*fixture, self.class.reserve(104, 1)],
      [*fixture, self.class.placed(1, 105, kind: M::KERNEL, prot: M::RW)],
      [*fixture, 'kremove 103 ok'], [*fixture, 'kremove 100 ok'], [*fixture, 'kremove 104 drop'],
      [*fixture, 'kremove 104 ok', self.class.release(100, 9)]
    ]
    lines = assert_agrees(scripts)
    assert_equal 6, lines.grep(/\A= (?:insert|release|part) #{M::EEXIST}\z/).size
  end

  # A deleted mapping stays until its range is released, holds its promise, and
  # a deletion that comes after a release finds the record gone.
  def test_deleted_mappings
    scripts = [
      [INIT, self.class.object(100, 4), 'deleted 100', "edges #{100 * P} #{P} 512", self.class.decommit(100, 4),
       self.class.commit(100, 4), self.class.protect(101, 1, M::NONE), self.class.release(100, 4)],
      [INIT, self.class.reserve(100, 2), 'deleted 100'],
      [INIT, self.class.object(100, 2), self.class.object(103, 2, object: 3), "deadrecord #{100 * P} #{5 * P}"]
    ]
    lines = assert_agrees(scripts)
    assert_includes lines, "= deadrecord #{M::ESTALE} #{M::OBJECT}"
    assert_equal 2, lines.grep(/\A= part #{M::EEXIST}\z/).size
  end

  # Plans are single use, for one tree, and name a generation; a deletion moves
  # the generation, so no plan writes a deleted object's handle back.
  def test_plans_go_stale
    lines = assert_agrees([[INIT, self.class.reserve(100, 2), self.class.reserve(102, 2), "twice #{100 * P} #{4 * P}"],
                           [INIT, self.class.object(100, 4), "markstale #{100 * P} #{4 * P} 100"],
                           [INIT, self.class.reserve(100, 2), "othertree #{100 * P} #{2 * P}"]])
    assert_includes lines, "= stale #{M::ESTALE}"
    assert_includes lines, "= markstale #{M::ESTALE}"
    assert_includes lines, "= othertree #{M::EINVAL}"
  end

  # The edge rule, over ranges and table spans, with regions the records leave
  # touched.
  def test_every_edge_over_every_range
    window = (16..48).step(3).to_a
    fixture = ['init 128', self.class.reserve(16, 8), self.class.commit(20, 2), self.class.object(32, 2),
               self.class.reserve(40, 8)]
    spans = [1, 4, 8, 16, 32, 64, 128, 256]
    scripts = window.product(window, spans).select { |low, high, _span| low < high }.map do |low, high, span|
      [*fixture, "edges #{low * P} #{(high - low) * P} #{span}"]
    end
    lines = assert_agrees(scripts)
    assert(lines.any? { |line| line.match?(/\AE 0 .*:1/) })
    assert(lines.any? { |line| line.match?(/\AE 0 .*:0/) })
    assert_includes lines, 'E 0'
  end

  def test_random_scripts_over_a_small_space
    rng = Random.new(SEED)
    assert_agrees(Array.new(RANDOM_SCRIPTS) { random_script(rng, low: 16, high: 80, top: 80) })
  end

  def test_random_scripts_at_the_top_of_the_address_space
    rng = Random.new(SEED + 1)
    top = M::LIMIT
    assert_agrees(Array.new(RANDOM_SCRIPTS) { random_script(rng, low: top - 64, high: top, top: top) })
  end

  # Long enough that the tree's rotations all run.
  def test_random_scripts_over_a_large_tree
    rng = Random.new(SEED + 2)
    assert_agrees(Array.new(4) { random_script(rng, low: 16, high: 4096, top: 4096, length: 1500) })
  end

  # ERX_MAPPINGS_MAX records: the tree refuses the next, a split included, and a
  # merge, a replacement of several records or a release frees room.
  def test_the_record_limit
    top = 1 << 24
    limit = M::MAX
    high = 16 + (2 * limit)
    full = ["init #{top}", 'quiet 1', "fill 16 #{limit} 1"]
    lines = assert_agrees([[*full, self.class.reserve(high + 10, 1), self.class.placed(1, high + 100),
                            self.class.reserve(17, 1), self.class.commit(16, 1), self.class.reserve(16, 6),
                            self.class.reserve(30, 3), self.class.placed(1, high + 100), self.class.release(16, 1),
                            self.class.placed(1, high + 100)]])
    assert_includes lines, "= insert #{M::ENOMEM}"

    split = ["init #{top}", 'quiet 1', "fill 16 #{limit - 1} 1", self.class.reserve(high + 10, 4),
             self.class.commit(high + 11, 1), self.class.release(high + 11, 1), self.class.release(16, 1),
             self.class.release(high + 11, 1)]
    lines = assert_agrees([split])
    assert_includes lines, "= part #{M::ENOMEM}"
    assert_includes lines, "= release #{M::ENOMEM}"
    assert_agrees([self.class.three_record_windows])
  end

  # At the limit, a replacement that splits the two records at its ends and
  # takes the one between grows nothing, so each plan is accepted: the count of
  # what a range holds must be exact, wherever the records hang in the tree.
  def self.three_record_windows
    ["init #{1 << 24}", 'quiet 1', "fill 16 #{M::MAX} 2",
     *(0...300).map { |index| reserve(16 + (3 * index) + 1, 6, mode: 'drop') }]
  end

  # Each of these wrong cores disagrees with the model, or stops the driver's
  # own checks, so the tests above can see each mistake.
  MUTANTS = {
    'no ceiling check' => ['return ((prot & ~ceiling) == 0);', 'return ((prot & ~ceiling) == 0 || prot != 0);'],
    'no kernel check in a part' => ["if (at.kind == ERX_MAP_KERNEL)\n\t\treturn (ERX_EEXIST);", 'if (false) return (ERX_EEXIST);'],
    'no kernel check in a cut' => ['if ((fold.kinds & MAP_KIND_BIT(ERX_MAP_KERNEL)) != 0)', 'if (fold.kinds == 0xff)'],
    'merge ignores offsets' => ["return (low->offset + (low->end.raw - low->start.raw) ==\n\t\t    high->offset);", 'return (true);'],
    'offset not moved' => ['piece.offset += start - piece.start.raw;', 'piece.offset += 0;'],
    'placement off the base' => ['uint64_t top = base > high ? high : base;',
                                 'uint64_t top = high + (base & 0);'],
    'highest hole not entered' => ['if (right != NULL && right->gap >= pages)', 'if (right != NULL && right->gap >= pages + 1000)'],
    'no rebalance' => ["int heavy;\n\n\tif ((hl > hr ? hl - hr : hr - hl) < 2) {", "int heavy;\n\n\tif (hl + hr < UINT32_MAX) {"],
    'stale plans run' => ['if (core->generation != target->generation)', 'if (false)'],
    'part not capped' => ['if (end - start > ERX_RANGE_PART_PAGES)', 'if (false)'],
    'object offset wraps' => ["(request->offset > request->object_pages ||\n\t    pages > request->object_pages - request->offset)",
                              '(pages > request->object_pages - request->offset)'],
    'a deletion keeps the generation' => ["map_update(path[--n]);\n\tcore->generation++;", 'map_update(path[--n]);'],
    'high straddler not popped' => ['core->pop_back = cut_high && !straddles_both ? 1 : 0;', 'core->pop_back = 0;'],
    'fold miscounts' => ['fold->count += node->count;', 'fold->count += 0 * node->count;'],
    'commit picks an offset' => ['after.offset = start;', 'after.offset = 0;'],
    'no double rotation' => ["if (map_height(node->child[heavy]->child[!heavy]) >\n\t    map_height(node->child[heavy]->child[heavy]))", 'if (false)'],
    'commit or decommit passes an object' => ["if (request->op != ERX_MAP_PROTECT &&\n\t    (at.kind == ERX_MAP_OBJECT || at.kind == ERX_MAP_DELETED))", 'if (false)'],
    'an insert picks a private offset' => ['new.offset = request->kind == ERX_MAP_PRIVATE ? start : request->offset;', 'new.offset = 0;'],
    'a private insert keeps an offset' => ['if (request->kind == ERX_MAP_PRIVATE && request->offset != 0)', 'if (false)'],
    'a hint is ignored' => ['map_hint_free(tree, request->addr, pages, &start)', '(false && map_hint_free(tree, request->addr, pages, &start))'],
    'a hint replaces' => ['return (map_fold_range(tree, *start, *start + pages).count == 0);', 'return (true);'],
    'a hint passes the top' => ['*start > map_tree_of(tree)->high ||', 'false ||'],
    'a ceiling ignores the object' => ['*ceiling = request->rights & request->object_ceiling;', '*ceiling = request->rights;'],
    'an apply trusts the report' => ['want = map_plan_spares(core);', 'want = plan->nspares + (0 * map_plan_spares(core));'],
    'a cut reports no clear' => ['core->clears = (fold.kinds & MAP_KINDS_TOUCHING) != 0;', 'core->clears = false;'],
    'a refused plan keeps its report' => ["if (status != ERX_OK)\n\t\tmap_plan_begin(tree, plan);", 'if (false) map_plan_begin(tree, plan);'],
    'a kernel page of any access' => ['if (kind == ERX_MAP_KERNEL && (prot != ERX_PROT_RW || flags != 0))', 'if (false)']
  }.freeze

  def test_the_tests_catch_a_wrong_core
    # A script the real core fails would count as catching every mutant.
    assert_agrees(mutant_scripts)
    MUTANTS.each do |name, (original, replacement)|
      source = File.read(File.join(@root, 'kernel/core/map.c'))
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
      path = File.join(@directory, "map-mutant-#{name.tr(' ', '-')}.c")
      File.write(path, source.sub(original) { replacement })
      mutant = build_driver(path, name: "mutant-#{name.tr(' ', '-')}")
      assert caught?(mutant), "mutant #{name} went unnoticed"
    end
  end

  private

  def caught?(mutant)
    @mutant_expected ||= mutant_scripts.flat_map { |script| predict(script) }
    @mutant_expected != run_script(mutant, mutant_scripts.flatten)
  rescue Erx::CommandError
    true
  end

  def mutant_scripts = (@mutant_scripts ||= build_mutant_scripts)

  def build_mutant_scripts
    klass = self.class
    one_page_holes = (16..600).step(2).map { |page| klass.reserve(page, 1) }
    wide_holes = [100, 200, 300, 400, 500].map { |page| klass.release(page, 6) }
    [[INIT, *FIXTURE, klass.protect(100, 14, M::RX), klass.protect(100, 14, M::R), klass.commit(100, 14)],
     [INIT, klass.object(100, 4), klass.kernel(104), klass.protect(102, 4, M::NONE), klass.release(102, 4)],
     [INIT, klass.kernel(104), klass.decommit(104, 1), klass.commit(104, 1), klass.protect(104, 1, M::NONE),
      klass.insert(page: 110, kind: M::KERNEL, prot: M::R)],
     [INIT, klass.object(100, 4), klass.commit(100, 4), klass.decommit(100, 4)],
     [INIT, klass.insert(page: 100, pages: 2, kind: M::PRIVATE, object: 1, prot: M::RW),
      klass.insert(page: 110, pages: 2, kind: M::PRIVATE, object: 1, prot: M::RW, offset: 5)],
     [INIT, klass.reserve(200, 4), klass.placed(2, 500, addr: 300 * P), klass.placed(2, 500, addr: 201 * P),
      klass.placed(2, 500, addr: 1023 * P), klass.placed(2, 500, addr: 1024 * P), klass.placed(2, 500, addr: 2000 * P)],
     [INIT, klass.object(100, 2, rights: M::RW, object_ceiling: M::R, prot: M::R), klass.protect(100, 2, M::RW)],
     [INIT, klass.reserve(100, 4), klass.commit(100, 4), klass.reserve(100, 4), klass.commit(100, 2)],
     [INIT, klass.reserve(100, 6), "lowspares #{102 * P} #{P}"],
     [INIT, klass.reserve(100, 2), klass.commit(100, 1), klass.release(100, 1), klass.reserve(110, 4), klass.commit(110, 2),
      klass.reserve(111, 2), klass.kernel(120), klass.release(120, 1)],
     *Array.new(2) { |index| random_script(Random.new(SEED + 3 + index), low: 16, high: 4096, top: 4096, length: 1500) },
     [INIT, klass.object(100, 4), klass.object(104, 4, offset: 9), klass.protect(100, 8, M::NONE), klass.placed(1, 90)],
     [INIT, klass.object(100, 4, offset: 7), klass.protect(101, 2, M::NONE), klass.release(100, 2)],
     [INIT, klass.reserve(100, 4), klass.commit(100, 2), klass.commit(102, 2)],
     [INIT, klass.reserve(100, 2), klass.reserve(102, 2), "twice #{100 * P} #{4 * P}"],
     [INIT, klass.object(100, 4), "markstale #{100 * P} #{4 * P} 100"],
     [INIT, klass.insert(page: 20, kind: M::OBJECT, object: 1, object_pages: 4096, offset: 5000, prot: M::R, ceiling: M::R)],
     ['init 1048576', klass.reserve(1024, 512), klass.commit(1024, 512)],
     ['init 4096', *one_page_holes, *wide_holes, *Array.new(6) { klass.placed(4, 601) }],
     klass.three_record_windows]
  end

  def plans(lines) = lines.grep(/\A= part 0/).map { |line| PlanLine.parse(line) }

  # A command over [low, high) that is usually sane and sometimes wild.
  def random_script(rng, low:, high:, top:, length: RANDOM_LENGTH)
    Array.new(length) { random_command(rng, low: low, high: high) }.unshift("init #{top}")
  end

  def random_range(rng, low, high)
    page = rng.rand(low...high)
    pages = 1 + rng.rand([high - page, rng.rand(2).zero? ? 4 : 32].min)
    [page, pages]
  end

  def random_command(rng, low:, high:)
    klass = self.class
    page, pages = random_range(rng, low, high)
    case rng.rand(13)
    when 0..1 then klass.reserve(page, pages)
    when 2 then random_object(rng, page, pages)
    when 3..4 then klass.commit(page, pages, object: rng.rand(1..3))
    when 5..6 then klass.decommit(page, pages)
    when 7 then klass.protect(page, pages, [M::NONE, M::R, M::RW, M::RX, M::RWX, 6].sample(random: rng))
    when 8 then klass.release(page, pages)
    when 9 then klass.placed(pages, rng.rand(low..high), addr: rng.rand(2).zero? ? 0 : rng.rand(low...high) * P)
    when 11 then klass.insert(page: page, pages: pages, kind: M::PRIVATE, object: rng.rand(1..3), prot: M::RW)
    when 10 then "edges #{page * P} #{pages * P} #{[1, 8, 64, 512].sample(random: rng)}"
    else klass.kernel(page)
    end
  end

  def random_object(rng, page, pages)
    ceiling = [M::R, M::RW, M::RX, M::RWX].sample(random: rng)
    prot = [M::NONE, ceiling & M::R, ceiling == M::RWX ? M::RW : ceiling].sample(random: rng)
    vm_flags = rng.rand(3).zero? ? M::FIXED | M::NOREPLACE : M::FIXED
    self.class.insert(page: page, pages: pages, vm_flags: vm_flags, kind: M::OBJECT, object: rng.rand(1..3), offset: page,
                      object_pages: page + pages, prot: prot, ceiling: ceiling)
  end

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(core, name:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *@sanitizer_flags,
                 '-D_DEFAULT_SOURCE', '-D_DARWIN_C_SOURCE', *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'),
                 core, File.join(@root, 'test/fixtures/map_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def run_script(program, script)
    input = File.join(@directory, "script-#{script.hash.abs}.txt")
    File.write(input, script.map { |line| "#{line}\n" }.join)
    record = @runner.run([program, input], name: 'map-driver', deadline: 300)
    File.read(record.fetch('log')).lines.map(&:chomp).grep(/\A(?:[=TDAELX] )|\AE 0\z/)
  end

  def predict(script)
    model = MapModel.new
    script.flat_map { |line| model.call(line) }
  end

  def assert_agrees(scripts)
    expected = scripts.flat_map { |script| predict(script) }
    actual = run_script(driver, scripts.flatten)
    mismatch = expected.each_index.find { |index| expected[index] != actual[index] }
    assert_nil mismatch, mismatch && "line #{mismatch}:\n  model:  #{expected[mismatch]}\n  driver: #{actual[mismatch]}"
    assert_equal expected.size, actual.size
    actual
  end
end
