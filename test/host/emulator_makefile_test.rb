# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The emulator's makefile reaches erts/lib_src's archives (ethread, erts_internal)
# only through lib_src's stamp, obj/TARGET/TYPE/MADE. This test runs GNU make on the
# stamp's rule as otp/erts/emulator/Makefile.in writes it, under a two-makefile
# model: an emulator whose executable depends on the stamp, and a lib_src whose
# stamp depends on its archive and the archive on its source.
class EmulatorMakefileTest < Minitest::Test
  MAKEFILE_IN = File.expand_path('../../otp/erts/emulator/Makefile.in', __dir__)
  STAMP_RULE = /^\$\(ERTS_LIB\):/
  # What make would otherwise read from the test's environment: an outer make's
  # flags and jobserver (MAKEFLAGS, MFLAGS, MAKELEVEL), extra flags (GNUMAKEFLAGS),
  # extra makefiles (MAKEFILES) and a replacement for the recursive $(MAKE) (MAKE).
  CLEAN_MAKE_ENVIRONMENT = %w[MAKEFLAGS MFLAGS MAKELEVEL GNUMAKEFLAGS MAKEFILES MAKE]
                           .to_h { |name| [name, nil] }.freeze

  # lib_src's own makefile, reduced to the chain that matters: the stamp is
  # rewritten only when the archive changed, and the archive only when its source did.
  LIB_SRC_MAKEFILE = <<~MAKE
    opt: obj/MADE
    obj/MADE: liberts_internal.a
    \tmkdir -p obj
    \techo $? > $@
    liberts_internal.a: erl_misc_utils.c
    \tcp erl_misc_utils.c $@
  MAKE

  def setup
    @root = File.realpath(Dir.mktmpdir('erx-emulator-makefile-'))
    @lib_src = File.join(@root, 'lib_src')
    @emulator = File.join(@root, 'emulator')
    write(File.join(@lib_src, 'Makefile'), LIB_SRC_MAKEFILE)
    write(File.join(@lib_src, 'erl_misc_utils.c'), 'stock')
    write(File.join(@emulator, 'Makefile'), emulator_makefile)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def test_an_edit_under_lib_src_reaches_the_emulator
    make_emulator
    backdate_everything
    write(File.join(@lib_src, 'erl_misc_utils.c'), 'changed')
    make_emulator
    assert_equal 'changed', File.read(beam), "the emulator linked lib_src's old archive"
  end

  # Asking lib_src's make on every build must not by itself make anything that
  # depends on the stamp (the executable, the yielding-C-function outputs) out of date.
  def test_a_build_with_nothing_changed_remakes_nothing
    make_emulator
    backdate_everything
    before = File.mtime(beam)
    make_emulator
    assert_equal before, File.mtime(beam)
  end

  private

  def beam = File.join(@emulator, 'beam')

  # The model emulator: its executable depends on the stamp, as the real one does
  # through DEPLIBS, under the real one's empty .SECONDARY, followed by the paragraph
  # of Makefile.in that holds the stamp's rule.
  def emulator_makefile
    <<~MAKE
      ERTS_LIB_DIR = #{@lib_src}
      TYPE = opt
      ERTS_LIB = $(ERTS_LIB_DIR)/obj/MADE

      .SECONDARY:

      beam: $(ERTS_LIB)
      \tcp $(ERTS_LIB_DIR)/liberts_internal.a $@

      #{stamp_rule_paragraph}
    MAKE
  end

  # The blank-line-separated paragraph of Makefile.in whose rule makes the stamp.
  # The rule and anything it alone needs sit together in that paragraph.
  def stamp_rule_paragraph
    paragraphs = File.read(MAKEFILE_IN).split(/\n[ \t]*\n/)
    matches = paragraphs.grep(STAMP_RULE)
    assert_equal 1, matches.size, "#{MAKEFILE_IN} must have one paragraph with the rule for $(ERTS_LIB)"
    matches.first
  end

  # Moves every file a minute into the past, so the edit that follows is newer than
  # anything made, whatever the file system's time resolution.
  def backdate_everything
    past = Time.now - 60
    Dir.glob(File.join(@root, '**', '*')).each { |path| File.utime(past, past, path) }
  end

  def make_emulator
    output, status = Open3.capture2e(CLEAN_MAKE_ENVIRONMENT, 'gmake', '--no-print-directory',
                                     '-C', @emulator, 'beam', stdin_data: '')
    assert status.success?, "gmake failed:\n#{output}"
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
end
