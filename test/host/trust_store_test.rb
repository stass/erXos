# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'minitest/autorun'
require 'openssl'
require 'tmpdir'
require_relative '../../tools/lib/erx/origin'
require_relative '../../tools/lib/erx/trust_store'

# The trust store the build writes from config/trust/ (docs/design-crypto.md, "The
# trust store", and its verification row): exactly the roots config/trust/ORIGIN.md
# records, in name order, each a self-signed CA certificate; and a root file that holds
# two certificates, a private key, more than 8 KiB or a non-ASCII byte is refused,
# naming the file.
class TrustStoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DIRECTORY = File.join(ROOT, Erx::TrustStore::DIRECTORY)
  BLOCK = /-----BEGIN CERTIFICATE-----\n.*?-----END CERTIFICATE-----\n/m

  # The record's rows, file name and certificate fingerprint, in the record's order.
  def recorded_roots
    File.read(File.join(DIRECTORY, 'ORIGIN.md')).lines.filter_map do |line|
      cells = line.strip.split('|').map(&:strip)
      next unless cells.size == 8

      _, file, _root, _publisher, _url, _file_sha256, fingerprint, _needed_by = cells
      next unless file.match?(/\A`[a-z0-9-]+\.pem`\z/)

      [file.delete('`'), fingerprint.delete('`')]
    end
  end

  def test_the_store_is_the_recorded_roots_in_name_order
    recorded = recorded_roots
    assert_equal 5, recorded.size
    assert_equal recorded.map(&:first).sort, recorded.map(&:first), 'the record lists the roots in name order'
    assert_equal recorded.map(&:first), Erx::TrustStore.roots(DIRECTORY).map { |path| File.basename(path) }

    store = Erx::TrustStore.store(DIRECTORY)
    assert_equal Erx::TrustStore.roots(DIRECTORY).map { |path| File.binread(path) }.join, store
    certificates = store.scan(BLOCK).map { |block| OpenSSL::X509::Certificate.new(block) }
    assert_equal recorded.map(&:last), certificates.map { |certificate| Digest::SHA256.hexdigest(certificate.to_der) }
    certificates.each do |certificate|
      assert_equal certificate.subject.to_s, certificate.issuer.to_s
      assert certificate.verify(certificate.public_key), "#{certificate.subject} verifies under its own key"
      constraints = certificate.extensions.find { |extension| extension.oid == 'basicConstraints' }
      assert_match(/CA:TRUE/, constraints&.value.to_s, "#{certificate.subject} is a CA")
    end
  end

  def test_a_root_file_of_anything_but_one_certificate_is_refused
    first, second = Erx::TrustStore.roots(DIRECTORY).first(2).map { |path| File.binread(path) }
    key = OpenSSL::PKey::EC.generate('prime256v1').private_to_pem
    {
      'two.pem' => first + second,
      'key.pem' => key,
      'key-after.pem' => first + key,
      'large.pem' => first + ("\n" * (9 * 1024 - first.bytesize)),
      'latin.pem' => first.sub('-----END CERTIFICATE-----', "-----END CERTIFICATE-----\xC3\xA9".b),
      'crlf.pem' => first.gsub("\n", "\r\n")
    }.each do |name, bytes|
      Dir.mktmpdir('trust-store-') do |directory|
        path = File.join(directory, name)
        File.binwrite(path, bytes)
        error = assert_raises(Erx::Error, name) { Erx::TrustStore.store(directory) }
        assert_includes error.message, path
      end
    end
  end

  # A test image's own root files follow the tree's, in the order given, each checked as
  # a tree root is; none given, the store is the tree's alone.
  def test_test_roots_follow_the_trees_and_are_checked_alike
    tree = Erx::TrustStore.store(DIRECTORY)
    first, second = Erx::TrustStore.roots(DIRECTORY).first(2)
    assert_equal tree + File.binread(second) + File.binread(first),
                 Erx::TrustStore.store(DIRECTORY, test_roots: [second, first].map { |path| fixture_root(path) })
    Dir.mktmpdir('trust-store-') do |directory|
      path = File.join(directory, 'two.pem')
      File.binwrite(path, File.binread(first) + File.binread(second))
      error = assert_raises(Erx::Error) { Erx::TrustStore.store(DIRECTORY, test_roots: [fixture_root(path)]) }
      assert_includes error.message, path
    end
  end

  def fixture_root(path) = Erx::TrustStore::TestRoot.new(path: path, source: 'tools/lib/erx/quotes_fixture.rb')

  def test_an_empty_directory_is_no_store
    Dir.mktmpdir('trust-store-') do |directory|
      assert_raises(Erx::Error) { Erx::TrustStore.store(directory) }
    end
  end

  # The record's inventory has no archive, so its archive_sha256 is the SHA-256 of the
  # listing shasum -a 256 prints for the roots, sorted by name, as the record says; a root
  # added or replaced without the record's update fails here.
  def test_the_records_listing_hash_is_of_the_roots
    listing = Erx::TrustStore.roots(DIRECTORY).map do |path|
      "#{Digest::SHA256.file(path).hexdigest}  #{File.basename(path)}\n"
    end.join
    inventory = Erx::Origin.new(root: DIRECTORY).inventory
    assert_equal Digest::SHA256.hexdigest(listing), inventory.fetch('archive_sha256')
  end

  # Where a release carries the store is where public_key's {unix, erxos} row reads it:
  # cacerts.pem of code:priv_dir(public_key), in erxos_paths/0 of pubkey_os_cacerts.
  def test_the_release_path_is_where_pubkey_os_cacerts_reads
    source = File.read(File.join(ROOT, 'otp/lib/public_key/src/pubkey_os_cacerts.erl'))
    body = source[/^erxos_paths\(\) ->\n(.*?)\.\n/m, 1]
    refute_nil body, 'pubkey_os_cacerts has no erxos_paths/0'
    priv, name = Erx::TrustStore::PATH.split('/')
    assert_equal 'priv', priv
    assert_includes body, "code:priv_dir(#{Erx::TrustStore::APPLICATION})"
    assert_includes body, "filename:join(Priv, \"#{name}\")"
  end
end
