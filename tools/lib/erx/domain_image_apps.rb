# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # OTP's applications that only the domains' runtime images can run
  # (docs/design-crypto.md, "Three runtime images"): asn1 and crypto, whose static NIFs
  # the interpreter and BeamAsm images link and the system image does not, and
  # public_key and ssh, whose every key operation calls crypto. TABLE is the one list of
  # them; the runtime builds' application list (Runtime::APPLICATIONS), the static NIF
  # archives and table every domain image links (NativeRuntime), and the releases that
  # carry them (ReleaseFiles) are each derived from it.
  module DomainImageApps
    # Each application, in release order, after those it depends on, under the static
    # NIF archive its static_lib target makes in lib/<application>/priv/lib/<target>, or
    # nil for an application without one.
    TABLE = { 'asn1' => 'asn1rt_nif.a', 'crypto' => 'crypto.a', 'public_key' => nil, 'ssh' => nil }.freeze
    APPLICATIONS = TABLE.keys.freeze
    # The applications with a static NIF archive, under that archive's name.
    NIF_ARCHIVES = TABLE.compact.freeze
  end
end
