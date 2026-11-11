# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'

module Erx
  module ABI
    # One signal of the table: its name without SIG in lower case (hup,
    # rtmin+1), its number, its default action and its alias or nil.
    SignalEntry = Struct.new(:name, :number, :action, :alias_name, keyword_init: true) do
      # A program may name it: listed, and not kept by the C library.
      def nameable? = action != 'reserved'
    end
    # The signal table: every signal in number order, and each alias with
    # the name of the signal it stands for.
    SignalTable = Struct.new(:signals, :aliases, keyword_init: true)

    # The signal and realtime lines of abi/signals.txt
    # (docs/design-programs.md, "Signal numbers").
    module Signals
      # Each default action with its number in the generated code; 0 is no
      # signal, so a lookup table's unlisted entries read as none.
      ACTIONS = %w[none terminate ignore stop continue reserved].each_with_index.to_h.freeze
      NAME = /\A[a-z][a-z0-9]{0,15}\z/
      # FreeBSD's _SIG_MAXSIG: signal numbers are 1 to 128.
      MAX_NUMBER = 128

      module_function

      def validate(by_kind)
        listed = by_kind.fetch('signal', []).map { |declaration| signal(declaration) }
        realtime = by_kind.fetch('realtime', [])
        realtime.drop(1).each { |declaration| declaration.fail!('the signal table takes one realtime line') }
        signals = (listed + realtime.first(1).flat_map { |declaration| realtime_signals(declaration) })
                  .sort_by(&:number)
        aliases = signals.select(&:alias_name).to_h { |signal| [signal.alias_name, signal.name] }
        line = (by_kind.fetch('signal', []) + realtime).first
        unique(signals.map(&:number), label: 'signal number', line: line)
        unique(signals.map(&:name) + aliases.keys, label: 'signal name', line: line)
        SignalTable.new(signals: signals.map(&:freeze).freeze, aliases: aliases.freeze).freeze
      end

      # The constants of the table: sig and the name of each signal whose
      # name is an identifier, and of each alias (ERX_SIGHUP, ERX_SIGIOT,
      # ERX_SIGRTMIN), and each default action's number (ERX_SIG_ACTION_STOP).
      def constants(table)
        return {} if table.signals.empty?

        numbers = table.signals.to_h { |signal| [signal.name, signal.number] }
        named = numbers.select { |name, _number| name.match?(NAME) }
        aliases = table.aliases.transform_values { |name| numbers.fetch(name) }
        named.merge(aliases).transform_keys { |name| "sig#{name}" }
             .merge(ACTIONS.transform_keys { |action| "sig_action_#{action}" })
      end

      def signal(declaration)
        declaration.fail!('signal does not take members') unless declaration.members.empty?
        name, number, action, keyword, alias_name, *rest = declaration.args
        unless rest.empty? && (keyword.nil? || (keyword == 'alias' && alias_name))
          declaration.fail!('expected signal NAME NUMBER ACTION [alias NAME]')
        end
        SignalEntry.new(name: name_of(name, declaration), number: number_of(number, declaration),
                        action: action_of(action, declaration),
                        alias_name: alias_name && name_of(alias_name, declaration))
      end

      # realtime FIRST LAST ACTION: rtmin, rtmin+1 up to the middle of the
      # range, then rtmax-N down to rtmax, as sig2str names them.
      def realtime_signals(declaration)
        declaration.fail!('realtime does not take members') unless declaration.members.empty?
        declaration.fail!('expected realtime FIRST LAST ACTION') unless declaration.args.size == 3
        first, last = declaration.args.first(2).map { |value| number_of(value, declaration) }
        action = action_of(declaration.args[2], declaration)
        declaration.fail!('realtime range is empty') unless first < last
        declaration.fail!('a real-time signal is never reserved') if action == 'reserved'
        middle = (first + last) / 2
        (first..last).map do |number|
          name = if number == first then 'rtmin'
                 elsif number <= middle then "rtmin+#{number - first}"
                 elsif number == last then 'rtmax'
                 else "rtmax-#{last - number}"
                 end
          SignalEntry.new(name: name, number: number, action: action)
        end
      end

      def name_of(value, declaration)
        declaration.fail!("invalid signal name #{value.inspect}") unless value&.match?(NAME)
        value.freeze
      end

      def number_of(value, declaration)
        number = Syntax.integer(value, line: declaration.line)
        declaration.fail!("signal number must be 1 to #{MAX_NUMBER}") unless number.between?(1, MAX_NUMBER)
        number
      end

      def action_of(value, declaration)
        declaration.fail!("unknown signal action #{value.inspect}") unless ACTIONS.key?(value) && value != 'none'
        value.freeze
      end

      def unique(values, label:, line:)
        duplicate = values.tally.find { |_value, count| count > 1 }
        line.fail!("duplicate #{label} #{duplicate.first}") if duplicate
      end
    end
  end
end
