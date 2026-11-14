# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/crypto_image'

# CryptoImage, the checks that the system image holds no OpenSSL and that the
# interpreter and BeamAsm images keep OpenSSL's seed path, over link-map lines and
# llvm-nm listings shaped as LLD and llvm-nm print them. The kept inputs are cut from a
# build's; each other test seeds one fault a check exists for and sees it fail.
class CryptoImageTest < Minitest::Test
  LIB = 'build/runtime/native/musl/lib'
  OPENSSL = 'build/runtime/native/openssl/prefix/lib'
  NIFS = 'build/runtime/native/otp/lib'
  SYSTEM_MAP = <<~MAP
    VMA              LMA     Size Align Out     In      Symbol
             2000             2000       80     4         build/runtime/native/otp/bin/libbeam.a(driver_tab.o):(.data.driver_tab)
  MAP
  SYSTEM_SYMBOLS = <<~NM
    0000000000003000 T erl_start
  NM
  DOMAIN_MAP = <<~MAP
    #{SYSTEM_MAP}         1000             1000       30     4         #{LIB}/libc.a(getrandom.o):(.text.getrandom)
             4000             4000      200     4         build/erts/driver_tab_crypto.o:(.data.driver_tab)
             5000             5000      400     4         #{OPENSSL}/libcrypto.a(libdefault-lib-rand_unix.o):(.text.syscall_random)
             6000             6000      400     4         #{NIFS}/crypto/priv/lib/aarch64-unknown-erxos/crypto.a(crypto_static.o):(.text.load)
             7000             7000      100     4         #{NIFS}/asn1/priv/lib/aarch64-unknown-erxos/asn1rt_nif.a(asn1_erl_nif_static.o):(.text)
  MAP
  DOMAIN_SYMBOLS = <<~NM
    #{SYSTEM_SYMBOLS}0000000000001000 T getrandom
    0000000000005000 T OPENSSL_cpuid_setup
    0000000000006000 T crypto_nif_init
    0000000000007000 T asn1rt_nif_nif_init
  NM

  def symbols(listing) = Erx::CryptoImage.symbols(listing)
  def system_problems(map, listing) = Erx::CryptoImage.system_problems(map_text: map, symbols: symbols(listing))
  def seed_problems(map, listing) = Erx::CryptoImage.seed_problems(map_text: map, symbols: symbols(listing))

  def test_the_system_image_without_openssl_passes
    assert_empty system_problems(SYSTEM_MAP, SYSTEM_SYMBOLS)
  end

  def test_the_system_image_linked_with_libcrypto_and_the_crypto_table_fails
    problems = system_problems(DOMAIN_MAP, DOMAIN_SYMBOLS)
    assert_includes problems, 'its link takes members of libcrypto.a'
    assert_includes problems, 'its link takes members of crypto.a'
    assert_includes problems, 'its link takes members of asn1rt_nif.a'
    assert_includes problems, 'its static NIF table names crypto_nif_init'
    assert_includes problems, "it defines OpenSSL's OPENSSL_cpuid_setup"
  end

  # OpenSSL's objects carried in by an archive of another name are still found.
  def test_openssl_under_another_archive_name_fails
    listing = "#{SYSTEM_SYMBOLS}0000000000005000 T ossl_rand_pool_new\n"
    assert_equal ["it defines OpenSSL's ossl_rand_pool_new"], system_problems(SYSTEM_MAP, listing)
  end

  def test_a_listing_without_erts_entry_fails
    assert_equal ['its symbols list no erl_start'], system_problems(SYSTEM_MAP, '')
  end

  def test_libcrypto_alone_in_the_system_image_fails_and_is_not_read_as_crypto_a
    map = "#{SYSTEM_MAP}  5000 5000 400 4 #{OPENSSL}/libcrypto.a(libcrypto-lib-armcap.o):(.text.OPENSSL_cpuid_setup)\n"
    assert_equal ['its link takes members of libcrypto.a'], system_problems(map, SYSTEM_SYMBOLS)
  end

  def test_a_domain_image_that_keeps_the_seed_path_passes
    assert_empty seed_problems(DOMAIN_MAP, DOMAIN_SYMBOLS)
  end

  # What rand_unix.c built without its edit links: syscall_random looks getentropy up
  # weakly, nothing pulls musl's getrandom.o, and getrandom is not defined.
  def test_the_unedited_rand_unix_fails
    map = DOMAIN_MAP.lines.grep_v(/getrandom\.o/).join
    listing = "#{DOMAIN_SYMBOLS.lines.grep_v(/getrandom/).join}                 w getentropy\n"
    assert_equal ["its link takes no getrandom.o from musl's libc.a", 'it does not define getrandom',
                  'it holds getentropy weak and undefined (w)'], seed_problems(map, listing)
  end

  # libbeam.a's driver_tab.o taken in place of the crypto table: no NIF init is named,
  # so crypto.a and libcrypto.a are not linked either.
  def test_a_domain_image_with_the_system_table_fails
    map = DOMAIN_MAP.lines.grep_v(/libcrypto|crypto\.a|asn1rt/).join
    problems = seed_problems(map, SYSTEM_SYMBOLS)
    assert_includes problems, 'its link takes no rand_unix member of libcrypto.a'
    assert_includes problems, 'its static NIF table names no crypto_nif_init'
    assert_includes problems, 'its static NIF table names no asn1rt_nif_nif_init'
  end
end
