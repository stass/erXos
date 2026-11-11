# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ABI
    module Protocols
      # The rules a frame protocol's table must meet before anything is
      # generated from it (docs/design-abi.md, "Program protocol"): kinds
      # nest at most DEPTH_MAX deep, the C check's stack; a union's cases are
      # told apart by arity and leading atoms; an ascending list has an
      # integer or atom key; a unique kind is never a list's element; a
      # refers names a list of tuples keyed by a small integer range that
      # occurs once in a frame. Each rule is checked here, so the emitters
      # only render.
      module Profile
        DEPTH_MAX = 16
        REFERS_RANGE_MAX = 4096
        # ERX_PROFILE_TOTALS_MAX of erx/profile.h.
        TOTALS_MAX = 8
        # The members that describe 9P2000.L's bytes, which a frame protocol refuses.
        NINE_P_ONLY = 'length, packed, local, errors, operation, writes and check describe 9P2000.L ' \
                      'and fail in a frame protocol'

        module_function

        # A file protocol takes none of the frame protocol's members.
        def operation_kinds!(declaration, kinds)
          kinds.each do |name, kind|
            frame_only = case kind.fetch(:form)
                         when 'union' then true
                         when 'map' then !kind.fetch(:optional).empty?
                         when 'integer'
                           # The file protocol's emitters read one of these per integer.
                           if %i[max values atom except].count { |option| kind[option] } > 1
                             declaration.fail!("kind #{name}: a file protocol's integer takes one of max, values, or ATOM and except")
                           end
                           kind[:unique] || kind[:refers] || kind[:min]
                         when 'text'
                           if kind.fetch(:max).fetch(:value) > LENGTHS.fetch(kind.fetch(:length))
                             declaration.fail!("kind #{name}: max past its #{kind.fetch(:length)} length")
                           end
                           kind[:sum] || kind.fetch(:assign) || kind.fetch(:path)
                         when 'list' then kind.fetch(:ascending)
                         end
            references = [*kind.fetch(:elements, []), kind[:element], *kind.fetch(:fields, []).map(&:last)]
            next unless frame_only || references.intersect?(FRAME_BUILTINS)

            declaration.fail!("kind #{name} uses a member only a frame protocol takes")
          end
        end

        def frames(declaration, name:, kinds:, frames:, totals:, version:, reader:, constants:, nine_p:)
          declaration.fail!('a frame protocol requires version N') unless version
          declaration.fail!(NINE_P_ONLY) if nine_p || nine_p_kinds?(kinds)
          frame_rules!(declaration, frames)
          used = Protocols.used_kinds(kinds, frames.map { |frame| frame.fetch(:kind) })
          unused = kinds.keys - used
          declaration.fail!("unused kinds #{unused.join(' ')}") unless unused.empty?
          kinds.each { |kind_name, kind| kind_rules!(declaration, kind_name, kind, kinds, totals) }
          summed = kinds.values.filter_map { |kind| kind[:sum] }.uniq
          declaration.fail!("unused totals #{(totals.keys - summed).join(' ')}") unless (totals.keys - summed).empty?
          frame_limit = "#{name.delete_prefix('erx_')}_frame_max"
          declaration.fail!("a frame protocol needs the limit #{frame_limit}") unless constants.key?(frame_limit)
          depth = frames.map { |frame| depth(frame.fetch(:kind), kinds) }.max
          declaration.fail!("kinds nest #{depth} deep, past #{DEPTH_MAX}") if depth > DEPTH_MAX
          unique = kinds.select { |_, kind| kind[:unique] }.keys
          declaration.fail!('a protocol has at most one unique kind') if unique.size > 1
          declaration.fail!("a protocol has at most #{TOTALS_MAX} totals") if totals.size > TOTALS_MAX
          refers = kinds.select { |_, kind| kind[:refers] }.map do |kind_name, kind|
            refers_rule(declaration, kind_name, kind, kinds, frames)
          end
          { name: name, module: "#{name}_grammar", source: declaration.line.path, version: version, reader: reader,
            kinds: kinds.freeze, totals: totals.freeze,
            frames: frames.map { |frame| frame.except(:line).freeze }.freeze,
            frame_max: { value: constants.fetch(frame_limit).value, constant: frame_limit }.freeze,
            depth: depth, unique: unique.first, refers: refers.freeze, cap_null: constants['cap_null']&.value }.freeze
        end

        def nine_p_kinds?(kinds)
          kinds.values.any? do |kind|
            kind[:length_given] || kind[:packed] || kind[:local] || kind[:atom]
          end
        end

        def frame_rules!(declaration, frames)
          names = frames.map { |frame| frame.fetch(:name) }
          declaration.fail!('duplicate frame') unless names.uniq.size == names.size
          forms = frames.map { |frame| frame.values_at(:direction, :tag, :slot) }
          declaration.fail!('two frames of one direction share a tag and slot form') unless forms.uniq.size == forms.size
        end

        def kind_rules!(declaration, kind_name, kind, kinds, totals)
          fail = ->(message) { declaration.fail!("kind #{kind_name}: #{message}") }
          fail.call('a kind is unique or refers, not both') if kind[:unique] && kind[:refers]
          case kind.fetch(:form)
          when 'union' then union_rules!(kind, fail)
          when 'list'
            fail.call('a unique kind is never a list\'s element') if kinds.dig(kind.fetch(:element), :unique)
            fail.call('an ascending list needs an integer or atom key') if kind.fetch(:ascending) && !key_kind(kind, kinds)
          when 'text'
            fail.call("sum names no total #{kind[:sum]}") if kind[:sum] && !totals.key?(kind[:sum])
            fail.call("a frame protocol's text refuses only nul") unless (kind.fetch(:refuse) - ['nul']).empty?
          end
        end

        # A case without fields is its single atom; cases with fields of one
        # arity and one case atom carry as many literal atoms, and differ in them.
        def union_rules!(kind, fail)
          cases = kind.fetch(:cases)
          names = cases.map { |item| item.fetch(:c_name) }
          fail.call('two cases share a C name') unless names.uniq.size == names.size
          atoms, tuples = cases.partition { |item| item.fetch(:fields).empty? }
          fail.call('a case without fields has no literal atoms') if atoms.any? { |item| item.fetch(:atoms).size > 1 }
          tuples.group_by { |item| [item.fetch(:atoms).size + item.fetch(:fields).size, item.fetch(:atoms).first] }
                .each_value do |group|
            selectors = group.map { |item| item.fetch(:atoms) }
            next if selectors.map(&:size).uniq.size == 1 && selectors.uniq.size == selectors.size

            fail.call('two cases are selected by the same arity and leading atoms')
          end
        end

        # The kind an ascending list orders by: its element's, or its first
        # field's when the element is a tuple; nil when that is no integer or atom.
        def key_kind(list, kinds)
          element = list.fetch(:element)
          element = kinds.dig(element, :elements)&.first || element if kinds.dig(element, :form) == 'tuple'
          kind = kinds[element]
          return element if %w[boolean signal].include?(element) || BASE_KINDS.include?(element) && element != 'alias'
          return element if kind && kind.fetch(:form) == 'integer'
          return element if kind && kind.fetch(:form) == 'union' && kind.fetch(:cases).all? { |item| item.fetch(:fields).empty? }

          nil
        end

        def refers_rule(declaration, kind_name, kind, kinds, frames)
          fail = ->(message) { declaration.fail!("kind #{kind_name}: #{message}") }
          list = kinds[kind.fetch(:refers)]
          fail.call("refers names no list #{kind[:refers]}") unless list && list.fetch(:form) == 'list'
          tuple = kinds[list.fetch(:element)]
          fail.call('refers names a list whose elements are not tuples') unless tuple && tuple.fetch(:form) == 'tuple'
          key = tuple.fetch(:elements).first
          key_low, key_high = bounds(key, kinds) || fail.call('the list it refers to has no integer key')
          fail.call("the key ranges over more than #{REFERS_RANGE_MAX} values") if key_high - key_low + 1 > REFERS_RANGE_MAX
          low, high = bounds(kind_name, kinds)
          fail.call('its range is not within the key\'s') unless low >= key_low && high <= key_high
          if frames.any? { |frame| occurrences(frame.fetch(:kind), kind.fetch(:refers), kinds) > 1 }
            fail.call("#{kind[:refers]} can occur twice in one frame")
          end
          { kind: kind_name, list: kind.fetch(:refers), key: key, low: key_low, range: key_high - key_low + 1 }.freeze
        end

        # The least and greatest value of an integer kind.
        def bounds(name, kinds)
          kind = kinds[name]
          return [0, (1 << INTEGER_BITS.fetch(name)) - 1] if INTEGER_BITS.key?(name)
          return nil unless kind && kind.fetch(:form) == 'integer'

          values = kind[:values]&.map { |item| item.fetch(:value) }
          [values&.min || kind.dig(:min, :value) || 0,
           values&.max || kind.dig(:max, :value) || (1 << INTEGER_BITS.fetch(kind.fetch(:base))) - 1]
        end

        # How many times target can occur in a value of kind: 2 stands for
        # "more than once", as under a list.
        def occurrences(name, target, kinds)
          return 1 if name == target

          kind = kinds[name]
          return 0 unless kind

          inner = case kind.fetch(:form)
                  when 'tuple' then kind.fetch(:elements)
                  when 'map' then kind.fetch(:fields).map(&:last)
                  when 'union' then kind.fetch(:cases).flat_map { |item| item.fetch(:fields) }
                  when 'list' then [kind.fetch(:element)]
                  else []
                  end
          count = inner.sum { |item| occurrences(item, target, kinds) }
          count = 2 * count if kind.fetch(:form) == 'list'
          # A union holds one case: the most any one case holds.
          count = kind.fetch(:cases).map { |item| item.fetch(:fields).sum { |field| occurrences(field, target, kinds) } }.max || 0 if kind.fetch(:form) == 'union'
          [count, 2].min
        end

        # The container levels a value of kind takes on the C check's stack: a
        # tuple, list, map or union of tuples takes one, a scalar none.
        def depth(name, kinds)
          kind = kinds[name]
          return 0 unless kind

          inner = case kind.fetch(:form)
                  when 'tuple' then kind.fetch(:elements)
                  when 'map' then kind.fetch(:fields).map(&:last)
                  when 'list' then [kind.fetch(:element)]
                  when 'union'
                    return 0 if kind.fetch(:cases).all? { |item| item.fetch(:fields).empty? }

                    kind.fetch(:cases).flat_map { |item| item.fetch(:fields) }
                  else return 0
                  end
          1 + (inner.map { |item| depth(item, kinds) }.max || 0)
        end
      end
    end
  end
end
