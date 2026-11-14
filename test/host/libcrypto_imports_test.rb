# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/libcrypto'

# Libcrypto::Imports, the check of what libcrypto.a references from outside it, over
# listings shaped as `llvm-nm -A` prints them. The listing that keeps every rule is cut
# from a build's; each other test seeds one fault the check exists for and sees it fail.
class LibcryptoImportsTest < Minitest::Test
  ARCHIVE = 'build/openssl/obj/libcrypto.a'
  KEPT = <<~LISTING
    #{ARCHIVE}:libcrypto-lib-armcap.o:                  U getauxval
    #{ARCHIVE}:libcrypto-lib-armcap.o: 0000000000000000 T OPENSSL_cpuid_setup
    #{ARCHIVE}:libdefault-lib-rand_unix.o:                  U clock_gettime
    #{ARCHIVE}:libdefault-lib-rand_unix.o:                  U getpid
    #{ARCHIVE}:libdefault-lib-rand_unix.o:                  U getrandom
    #{ARCHIVE}:libdefault-lib-rand_unix.o: 0000000000000010 T ossl_pool_acquire_entropy
    #{ARCHIVE}:libcrypto-lib-bio_lib.o:                  U fopen
  LISTING

  def violations(listing) = Erx::Libcrypto::Imports.violations(listing)

  def test_a_listing_that_keeps_every_rule_has_no_violation
    assert_empty violations(KEPT)
  end

  def test_an_object_listing_names_its_member_by_file
    members = Erx::Libcrypto::Imports.members("obj/libdefault-lib-rand_unix.o:                  U getrandom\n")

    assert_equal({ 'libdefault-lib-rand_unix.o' => { 'getrandom' => 'U' } }, members)
  end

  # rand_unix.c without its edit: getentropy looked up weakly, no getrandom.
  def test_a_weak_getentropy_and_no_getrandom_fail
    listing = KEPT.sub('U getrandom', 'w getentropy')

    assert_equal ['libdefault-lib-rand_unix.o references getentropy (w)',
                  'libdefault-lib-rand_unix.o does not reference getrandom strongly'], violations(listing)
  end

  def test_a_second_seed_method_in_rand_unix_fails
    listing = KEPT + "#{ARCHIVE}:libdefault-lib-rand_unix.o:                  U open\n"

    assert_equal ['libdefault-lib-rand_unix.o references open (U)'], violations(listing)
  end

  # armcap.c without its edit: the SIGILL probe, and no getauxval.
  def test_the_sigill_probe_fails
    listing = KEPT.sub('U getauxval', 'U sigaction')

    assert_equal ['libcrypto-lib-armcap.o does not reference getauxval strongly',
                  'libcrypto-lib-armcap.o references sigaction (U)'], violations(listing)
  end

  def test_code_loading_in_any_member_fails
    listing = KEPT + "#{ARCHIVE}:libcrypto-lib-dso_dlfcn.o:                  U dlopen\n"

    assert_equal ['libcrypto-lib-dso_dlfcn.o references dlopen (U)'], violations(listing)
  end

  def test_a_missing_member_fails_rather_than_passing_unchecked
    listing = KEPT.lines.grep_v(/armcap/).join

    assert_equal ['libcrypto-lib-armcap.o is not in the archive'], violations(listing)
  end
end
