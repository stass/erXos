# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'

module Erx
  # The development host's operating system, for the few decisions that
  # differ between the hosts erXos builds on (README.md, "Host setup"):
  # macOS first, then FreeBSD and Linux. New decisions read NAME here;
  # older ones still match the platform string themselves.
  module HostOs
    NAME = case RbConfig::CONFIG.fetch('host_os')
           when /darwin/ then :macos
           when /freebsd/ then :freebsd
           when /linux/ then :linux
           else :other
           end

    MACOS = NAME == :macos
    FREEBSD = NAME == :freebsd
    LINUX = NAME == :linux

    # The C and C++ compilers for the programs the Fiasco build runs on the host: the
    # Kconfig tools (fixdep, conf, variable HOSTCC) and the L4Re make system's tools
    # (libgendep, elf-patcher, variables HOST_CC and HOST_CXX). The inherited rules
    # default to `gcc` and `g++`, which macOS keeps (Xcode ships them as clang shims) and
    # FreeBSD lacks; FreeBSD and Linux have the system compilers `cc` and `c++`.
    HOST_CC = MACOS ? 'gcc' : 'cc'
    HOST_CXX = MACOS ? 'g++' : 'c++'

    # The linker flags that make a NIF: a library the emulator loads, whose
    # references to the emulator's own functions resolve at load time. macOS
    # calls such a library a bundle; elsewhere it is a position-independent
    # shared object.
    NIF_LINK_FLAGS = (MACOS ? %w[-bundle -undefined dynamic_lookup] : %w[-shared -fPIC]).freeze

    # The environment under which an emulator started in directory finds a
    # NIF there that a module loads by its bare name (erlang:load_nif("name",
    # 0), as erXos's own modules do): macOS's dlopen falls back to the working
    # directory, FreeBSD's and Linux's search only LD_LIBRARY_PATH, which keeps
    # what the caller's held after it.
    def self.nif_search_environment(directory, env: ENV)
      return {} if MACOS

      { 'LD_LIBRARY_PATH' => [directory, *env.fetch('LD_LIBRARY_PATH', '').split(':').reject(&:empty?)].join(':') }
    end
  end
end
