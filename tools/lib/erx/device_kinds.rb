# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The host tools' reader of include/erx/device_kinds.h, the C table of the kinds of device
  # the root and the domain library read: erx_device_kinds, the kinds a give drives, and
  # erx_uart_kinds, the UARTs a console may be. The tools read the rows the C code reads, so
  # a kind is one row in the header and nowhere else.
  module DeviceKinds
    SOURCE = 'include/erx/device_kinds.h'
    # One row: { ERX_MF_DEVICE_ROLE_ROLE, "compatible", "role word", "peripheral" }.
    ROW = /\A\s*\{\s*ERX_MF_DEVICE_ROLE_([A-Z0-9_]+),\s*"([^"]+)",\s*"(\w+)",\s*"(\w+)"\s*\},\s*\z/
    # The header whose ERX_BOOT_NAME_WORD_MAX bounds a record's name word, a role word or a
    # peripheral, with its NUL.
    BOOT_WORDS = 'include/erx/boot_words.h'
    # The PL011's peripheral, the one UART kind whose platform row carries its clock.
    PL011 = 'pl011'
    # The tree whose header the running tools were checked out with.
    CODE_ROOT = File.expand_path('../../..', __dir__)

    # role is the manifest's mf_device_role member, in lower case, as the platform records name it.
    Kind = Data.define(:role, :compatible, :role_word, :peripheral)

    module_function

    # The kinds a give drives: each device of one in a held unit gets a given record.
    def given(root) = read(root, 'erx_device_kinds')

    # The UARTs a console may be: the console's record is its row's role word and PERIPHERAL.
    def uarts(root) = read(root, 'erx_uart_kinds', role: 'uart')

    # The PERIPHERAL of each compatible string a console may have, as Manifest::Context takes them.
    def uart_peripherals(root) = uarts(root).to_h { |kind| [kind.compatible, kind.peripheral] }.freeze

    # The compatible string of the UART kind of peripheral.
    def uart_compatible(peripheral, root: CODE_ROOT)
      kind = uarts(root).find { |row| row.peripheral == peripheral }
      raise Error, "#{SOURCE}: no UART kind of peripheral #{peripheral}" if kind.nil?

      kind.compatible
    end

    # Every row of table, in order. A row this reader cannot take whole, a name longer than a
    # record holds, a row of a role other than role when one is given, two rows of one role
    # and compatible string (the C lookups take the first), an empty table or none fails it,
    # rather than a row going unread.
    def read(root, table, role: nil)
      body = File.read(File.join(root, SOURCE))[/^static const erx_device_kind_t #{table}\[\] = \{\n(.*?)^\};/m, 1]
      raise Error, "#{SOURCE}: no #{table} table" if body.nil?

      name_max = name_max(root)
      kinds = body.lines.reject { |line| line.strip.empty? }.map { |line| kind(line, name_max) }
      raise Error, "#{SOURCE}: an empty #{table} table" if kinds.empty?
      stray = kinds.find { |kind| role && kind.role != role }
      raise Error, "#{SOURCE}: #{table} holds a #{stray.role} row" if stray
      raise Error, "#{SOURCE}: #{table} repeats a kind" unless kinds.uniq { |kind| [kind.role, kind.compatible] }.size == kinds.size

      kinds.freeze
    end

    # The longest name a record holds: ERX_BOOT_NAME_WORD_MAX less its NUL.
    def name_max(root)
      bound = File.read(File.join(root, BOOT_WORDS))[/^#define ERX_BOOT_NAME_WORD_MAX\s+(\d+)u$/, 1]
      raise Error, "#{BOOT_WORDS}: no ERX_BOOT_NAME_WORD_MAX" if bound.nil?

      Integer(bound) - 1
    end

    def kind(line, name_max)
      match = ROW.match(line)
      raise Error, "#{SOURCE}: unreadable row #{line.strip.inspect}" if match.nil?

      role, compatible, role_word, peripheral = match.captures
      long = [role_word, peripheral].find { |name| name.bytesize > name_max }
      raise Error, "#{SOURCE}: #{long} is longer than a record's #{name_max}-byte name" if long

      Kind.new(role: role.downcase, compatible: compatible, role_word: role_word, peripheral: peripheral)
    end
    private_class_method :read, :name_max, :kind
  end
end
