# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/fiasco_origins'

# A made-up Fiasco-style tree: a root LICENSE.spdx whose root package and
# whose lib package both say MIT, and files under lib whose own text says
# otherwise. The inventory records each file's own grant, which the package
# declaration does not override, and a notice it cannot read as unrecognised.
class FiascoOriginsTest < Minitest::Test
  LGPL_NOTICE = <<~SOURCE
    /*
     * This library is free software; you can redistribute it and/or
     * modify it under the terms of the GNU Lesser General Public
     * License as published by the Free Software Foundation; either
     * version 2.1 of the License, or (at your option) any later version.
     */
    int cancel(void);
  SOURCE

  FILES = {
    'LICENSE.spdx' => "DataLicense: CC0-1.0\n\nPackageName: lib\nPackageFileName: ./lib\n" \
                      "PackageLicenseConcluded: MIT\n",
    'lib/notice.c' => LGPL_NOTICE,
    'lib/declared.c' => "/* SPDX-License-Identifier: LGPL-2.1-only */\nint f(void);\n",
    'lib/gpl2.cpp' => "/*\n * This file is distributed under the terms of the GNU General Public\n" \
                      " * License, version 2. Please see the COPYING-GPL-2 file for details.\n */\n",
    'lib/unversioned.c' => "/* Distributed under the terms of the GNU General Public License. */\n",
    # A pointer the reviewed notice table lists (bootstrap's armada38x.cc),
    # and the same pointer with words added, which it does not.
    'lib/pointer.c' => "/*\n * (c) 2015\n * Author(s)\n *\n" \
                       " * License: see LICENSE.spdx (in this directory or the directories above)\n */\nint g(void);\n",
    'lib/pointer_plus.c' => "/*\n * (c) 2015\n * Author(s)\n *\n" \
                            " * License: see LICENSE.spdx (in this directory or the directories above),\n" \
                            " * for evaluation only\n */\nint g(void);\n",
    'lib/plain.c' => "int h(void);\n"
  }.freeze

  def licenses(files, part:)
    Dir.mktmpdir do |directory|
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(directory, path)))
        File.write(File.join(directory, path), text)
      end
      Erx::Origin.new(root: directory).write(repository: 'https://example.org/fixture', revision: '1',
                                             archive_sha256: 'a' * 64,
                                             review: Erx::FiascoOrigins.profile(directory, part: part))
      Erx::Origin.new(root: directory).inventory.fetch('files').transform_values { |row| row.fetch('license') }
    end
  end

  def test_a_files_own_notice_precedes_the_package_declaration
    # The reviewed LICENSE.spdx rule judged bootstrap's own bytes, not these.
    assert_equal({ 'LICENSE.spdx' => 'LicenseRef-unrecognized-notice',
                   'lib/notice.c' => 'LGPL-2.1-or-later',
                   'lib/declared.c' => 'LGPL-2.1-only',
                   'lib/gpl2.cpp' => 'GPL-2.0-only',
                   'lib/unversioned.c' => 'LicenseRef-unrecognized-notice',
                   'lib/pointer.c' => 'MIT',
                   'lib/pointer_plus.c' => 'LicenseRef-unrecognized-notice',
                   'lib/plain.c' => 'MIT' }, licenses(FILES, part: 'bootstrap'))
  end

  # A pointer counts only in the import it was reviewed in.
  def test_a_pointer_of_another_import_is_unrecognized
    assert_equal 'LicenseRef-unrecognized-notice',
                 licenses(FILES.slice('LICENSE.spdx', 'lib/pointer.c'), part: 'mk').fetch('lib/pointer.c')
  end
end
