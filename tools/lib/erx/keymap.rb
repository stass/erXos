# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'generation_plan'

module Erx
  # The keyboard layouts (docs/design-display.md, "Input events"): every file
  # abi/keymaps/NAME.txt, read and checked whole, becomes one table of the
  # generated Erlang module erx_keymap, which the display's input router alone
  # calls. A row's code is a member of the enum evdev of abi/formats/evdev.txt
  # and a special rune a member of the enum input_rune of abi/formats/input.txt,
  # so a layout can name only what those two closed sets declare: a key state or
  # KEY_MAX, which share the KEY_ prefix but are limits, is no code.
  #
  # A layout file is lines of space-separated tokens, with # starting a comment:
  #
  #   keymap NAME                                   once, NAME the file's name
  #   key      CODE NONE SHIFT CTL ALTGR SHIFTALTGR [caps]
  #   modifier CODE RUNE shift|ctl|alt|altgr
  #   lock     CODE RUNE caps
  #   button   CODE 1|2|4                           the Plan 9 button bit
  #
  # where each layer of a key, and a modifier's or lock's rune, is an entry: one
  # printable ASCII character, U+ and four to six hexadecimal digits (U+0000 types
  # nothing), or a special rune's name, its input_rune member with the first
  # letter capitalized (kup is Kup).
  module Keymap
    class LayoutError < Error; end

    LAYOUTS = 'abi/keymaps/*.txt'
    OUTPUT = 'erlang/apps/erx_display/src/erx_keymap.erl'
    GENERATOR = 'tools/lib/erx/keymap.rb'
    MAX_LAYOUT_BYTES = 65_536
    CODE_ENUM = 'evdev'
    RUNE_ENUM = 'input_rune'
    LAYERS = %w[none shift ctl altgr shiftaltgr].freeze
    MODIFIERS = %w[shift ctl alt altgr].freeze
    LOCKS = %w[caps].freeze
    BUTTONS = { '1' => 1, '2' => 2, '4' => 4 }.freeze
    LAYOUT_NAME = /\A[a-z][a-z0-9_]{0,62}\z/

    # A code a row names: its member of the enum evdev and its value.
    Code = Data.define(:member, :value)
    # A layer's entry: a code point, and the input_rune member it was named by,
    # or nil for a character or U+ entry.
    Entry = Data.define(:point, :rune)
    Key = Data.define(:code, :layers, :caps)
    Modifier = Data.define(:code, :rune, :modifier)
    Lock = Data.define(:code, :rune, :lock)
    Button = Data.define(:code, :bit)
    # A checked layout: its name and its rows in the order of their codes.
    Layout = Data.define(:name, :rows)
    # The two closed sets a layout is checked against, each by the token a
    # layout spells: 'KEY_A' => Code, 'Kup' => Entry.
    Vocabulary = Data.define(:codes, :runes)

    module_function

    # The plan Erx::Generated publishes into the build tree. It reads every
    # layout the glob finds and every ABI source, which the two enums come from.
    def generation(root:)
      root = File.realpath(root)
      sources = ABI::Sources.read(root: root)
      vocabulary = vocabulary(ABI::Model.validate(sources))
      paths = Dir.glob(LAYOUTS, base: root).sort
      raise LayoutError, "no keyboard layout matches #{LAYOUTS}" if paths.empty?

      texts = paths.to_h { |path| [path, BoundedFile.read(File.join(root, path), maximum: MAX_LAYOUT_BYTES)] }
      layouts = texts.map { |path, text| parse(path: path, text: text, vocabulary: vocabulary) }
      reads = sources.inputs.merge(texts).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      GenerationPlan.new(files: { OUTPUT => erlang(layouts).freeze }, reads: reads, globs: { LAYOUTS => paths })
    end

    # The key and button codes and the special runes, from the enums alone.
    def vocabulary(schema)
      codes = enum(schema, CODE_ENUM).members
                    .to_h { |member, value| [member.upcase, Code.new(member: member, value: value)] }
      runes = enum(schema, RUNE_ENUM).members
                    .to_h { |member, value| [member.capitalize, Entry.new(point: value, rune: member)] }
      Vocabulary.new(codes: codes.freeze, runes: runes.freeze)
    end

    def enum(schema, name)
      type = schema.types[name]
      raise LayoutError, "the ABI declares no enum #{name}" unless type.is_a?(ABI::EnumType) && !type.flags

      type
    end
    private_class_method :enum

    # The layout of the file at path, whose bytes are text, or a LayoutError
    # naming the file, the line and what is wrong there.
    def parse(path:, text:, vocabulary:)
      name = File.basename(path, '.txt')
      raise LayoutError, "#{path}: #{name.inspect} is not a layout name" unless name.match?(LAYOUT_NAME)

      declared = nil
      rows = {}
      text.b.split("\n", -1).each.with_index(1) do |line, number|
        where = "#{path}:#{number}"
        refuse_bytes(line, where: where)
        tokens = line.partition('#').first.strip.split(/ +/)
        next if tokens.empty?

        if tokens.first == 'keymap'
          raise LayoutError, "#{where}: a second keymap line" if declared
          raise LayoutError, "#{where}: keymap takes one name" unless tokens.size == 2
          raise LayoutError, "#{where}: keymap #{tokens[1]} in a file named #{name}" unless tokens[1] == name

          declared = tokens[1]
          next
        end
        raise LayoutError, "#{where}: a row before the keymap line" unless declared

        row = row(tokens, vocabulary: vocabulary, where: where)
        if rows.key?(row.code.value)
          raise LayoutError, "#{where}: #{tokens[1]} has a row already"
        end

        rows[row.code.value] = row
      end
      raise LayoutError, "#{path}: no keymap line" unless declared

      Layout.new(name: name, rows: rows.sort.map(&:last).freeze)
    end

    # Only printable ASCII and the space reach the tokenizer: a byte above 0x7f
    # or a control byte (a tab, a carriage return) is refused, not read around.
    def refuse_bytes(line, where:)
      byte = line.each_byte.find { |candidate| candidate > 0x7e || candidate < 0x20 }
      return unless byte

      kind = byte > 0x7f ? 'a byte above 0x7f' : 'a control byte'
      raise LayoutError, format('%s: %s, 0x%02x', where, kind, byte)
    end
    private_class_method :refuse_bytes

    # One row's tokens, matched whole by their keyword and width; a row of a
    # known keyword and another width is refused as such.
    def row(tokens, vocabulary:, where:)
      code = ->(name) { code(name, vocabulary: vocabulary, where: where) }
      entry = ->(token) { entry(token, vocabulary: vocabulary, where: where) }
      key_width = 2 + LAYERS.size
      case tokens
      in ['key', name, *layers] if tokens.size == key_width
        Key.new(code: code.call(name), layers: LAYERS.zip(layers.map(&entry)).to_h.freeze, caps: false)
      in ['key', name, *layers, 'caps'] if tokens.size == key_width + 1
        Key.new(code: code.call(name), layers: LAYERS.zip(layers.map(&entry)).to_h.freeze, caps: true)
      in ['key', *] if tokens.size == key_width + 1
        raise LayoutError, "#{where}: a key row ends in caps or in its last layer"
      in ['modifier', name, rune, modifier]
        raise LayoutError, "#{where}: #{modifier} is not a modifier" unless MODIFIERS.include?(modifier)

        Modifier.new(code: code.call(name), rune: entry.call(rune), modifier: modifier)
      in ['lock', name, rune, lock]
        raise LayoutError, "#{where}: #{lock} is not a lock" unless LOCKS.include?(lock)

        Lock.new(code: code.call(name), rune: entry.call(rune), lock: lock)
      in ['button', name, bit]
        Button.new(code: code.call(name),
                   bit: BUTTONS.fetch(bit) { raise LayoutError, "#{where}: #{bit} is not a Plan 9 button bit" })
      in ['key' | 'modifier' | 'lock' | 'button' => keyword, *]
        raise LayoutError, "#{where}: a #{keyword} row of #{tokens.size} tokens"
      in [keyword, *]
        raise LayoutError, "#{where}: #{keyword} is not a row of a layout"
      end
    end
    private_class_method :row

    def code(name, vocabulary:, where:)
      vocabulary.codes.fetch(name) do
        raise LayoutError, "#{where}: #{name} is not a key or button code of the enum evdev"
      end
    end
    private_class_method :code

    def entry(token, vocabulary:, where:)
      case token
      when /\A[!-~]\z/
        Entry.new(point: token.ord, rune: nil)
      when /\AU\+(\h{4,6})\z/
        point = Regexp.last_match(1).to_i(16)
        raise LayoutError, "#{where}: #{token} is a surrogate" if point.between?(0xd800, 0xdfff)
        raise LayoutError, "#{where}: #{token} is past U+10FFFF" if point > 0x10ffff

        Entry.new(point: point, rune: nil)
      else
        vocabulary.runes.fetch(token) do
          raise LayoutError, "#{where}: #{token} is not a special rune of the enum input_rune"
        end
      end
    end
    private_class_method :entry

    # erx_keymap: layouts/0, and row/2, one clause for each row of each layout
    # in code order and a last clause per layout for a code it has no row for.
    # A layout's atom is quoted, so a name that is a reserved word (end, of)
    # is an atom all the same.
    def erlang(layouts)
      names = layouts.map { |layout| "'#{layout.name}'" }
      clauses = layouts.zip(names).flat_map do |layout, atom|
        layout.rows.map { |row| clause(atom, row) } + ["row(#{atom}, _Code) ->\n    none"]
      end
      <<~ERLANG
        %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
        %% SPDX-License-Identifier: BSD-2-Clause
        %% Generated by #{GENERATOR} from #{LAYOUTS}; do not edit.
        -module(erx_keymap).
        -moduledoc """
        The keyboard layouts (docs/design-display.md, "Input events"): each
        layout's row for every evdev key or button code it maps. The input
        router alone calls it, and selects a key's layer from the modifiers
        held.
        """.

        -include("generated/erx_abi.hrl").

        -export([layouts/0, row/2]).
        -export_type([layout/0, rune/0, layers/0, row/0]).

        -type layout() :: #{names.join(' | ')}.
        %% A code point; 0 where the key types nothing at that layer.
        -type rune() :: 0..16#10ffff.
        -type layers() :: \#{#{LAYERS.map { |layer| "#{layer} := rune()" }.join(",\n                    ")}}.
        %% A key typing at its layers, true when Caps Lock shifts it; a modifier
        %% and a lock with their runes; a pointer button by its Plan 9 bit.
        -type row() :: {key, layers(), Caps :: boolean()}
                     | {modifier, rune(), #{MODIFIERS.join(' | ')}}
                     | {lock, rune(), #{LOCKS.join(' | ')}}
                     | {button, #{BUTTONS.values.join(' | ')}}.

        -doc "Every layout the tree has.".
        -spec layouts() -> [layout(), ...].
        layouts() ->
            [#{names.join(', ')}].

        -doc "The row of an evdev code in a layout, or none if it maps no row.".
        -spec row(layout(), non_neg_integer()) -> row() | none.
        #{clauses.join(";\n")}.
      ERLANG
    end
    private_class_method :erlang

    def clause(layout, row)
      head = "row(#{layout}, ?#{ABI::Names.macro("#{CODE_ENUM}_#{row.code.member}")}) ->\n    "
      head + case row
             in Key(layers:, caps:)
               fields = layers.map { |layer, value| "#{layer} => #{literal(value)}" }
               "{key, \#{#{fields.join(",\n            ")}},\n     #{caps}}"
             in Modifier(rune:, modifier:) then "{modifier, #{literal(rune)}, #{modifier}}"
             in Lock(rune:, lock:) then "{lock, #{literal(rune)}, #{lock}}"
             in Button(bit:) then "{button, #{bit}}"
             end
    end
    private_class_method :clause

    # A special rune by its macro, a printable character as $c, and any other
    # code point in hexadecimal.
    def literal(entry)
      return "?#{ABI::Names.macro("#{RUNE_ENUM}_#{entry.rune}")}" if entry.rune
      return '$\\\\' if entry.point == 0x5c
      return "$#{entry.point.chr}" if entry.point.between?(0x21, 0x7e)

      format('16#%04x', entry.point)
    end
    private_class_method :literal
  end
end
