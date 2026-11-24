# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The verdicts of tools/ble_board_check.rb: pure functions from what a blew run
  # printed and how it exited to passed, failed or unknown. blew's exit codes are its
  # README's "Exit codes" table: 0 success, 2 no matching device, 3 Bluetooth
  # unavailable or not permitted, 4 timeout, 5 an operation failed, 6 invalid
  # arguments. Each step names the exit codes that say something about the board (its
  # deciding codes); every other exit, and a run with no exit code (killed on its
  # deadline), is unknown, never a guess.
  module BleBoardCheck
    NUS_SERVICE = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E'
    NUS_RX = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'

    # What a blew run printed (its standard output and error together) and its exit
    # code, nil when it was killed.
    Run = Data.define(:output, :exit_code)
    Outcome = Data.define(:verdict, :detail)

    # A step's blew arguments after the global options (none for a step blew cannot
    # run yet), the exit codes that decide it, and its verdict on the output and the
    # exit code.
    Step = Data.define(:name, :argv, :deciding, :check)

    # The scan's verdict, and the identifier of the board when the verdict is passed.
    Scan = Data.define(:outcome, :id)

    # A CoreBluetooth device identifier, the only thing of a scan that reaches a script.
    IDENTIFIER = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/.freeze

    # One line of `blew --out kv scan`: a name holding a space or a quote is quoted,
    # with only the quote escaped.
    SCAN_LINE = /\Aid=(?<id>#{IDENTIFIER})\ name=(?:"(?<quoted>(?:\\"|[^"])*)"|(?<bare>[^\s"]+))
                 \ rssi=-?\d+\ services=(?:"[^"]*"|\S*)\z/x.freeze
    # The line ArgumentParser prints for the code of a failed command, then exits 1.
    EXIT_LINE = /^Error: exit code (\d+)$/.freeze

    NO_DEVICE = Outcome.new(verdict: :unknown, detail: 'no single device to connect to')

    module_function

    def outcome(verdict, detail) = Outcome.new(verdict: verdict, detail: detail)

    # The scan of the whole room, kept apart from blew's own --name, a substring match
    # that picks the strongest signal, so that another device cannot stand in for the
    # board. A line that is no scan line (a name holding a newline can make one)
    # leaves the scan unknown. Exit 5 says only that blew could not scan, as
    # Bluetooth being off does.
    def scan_result(run, name)
      lines = run.output.each_line(chomp: true).reject(&:empty?)
      return Scan.new(outcome: outcome(:unknown, 'the scan is not one line per device'), id: nil) unless lines.all? { |line| SCAN_LINE.match?(line) }

      ids = lines.filter_map { |line| board_id(line, name) }
      result = judge(run, deciding: [0, 2]) do |_output, _code|
        case ids.size
        when 1 then outcome(:passed, 'advertises its name')
        when 0 then outcome(:failed, 'no device advertises its name')
        else outcome(:unknown, "#{ids.size} devices advertise its name")
        end
      end
      Scan.new(outcome: result, id: result.verdict == :passed ? ids.first : nil)
    end

    def board_id(line, name)
      found = SCAN_LINE.match(line)
      advertised = found[:quoted] ? found[:quoted].gsub('\\"', '"') : found[:bare]
      found[:id] if advertised == name
    end

    # The exit code blew reports: when it exited 1 the last "Error: exit code N" line
    # of its output, the code of the command that failed; else its own exit code.
    def blew_exit(run)
      last = run.output.scan(EXIT_LINE).last
      run.exit_code == 1 && last ? Integer(last.first, 10) : run.exit_code
    end

    def judge(run, deciding:, &check)
      code = blew_exit(run)
      return outcome(:unknown, (code ? "blew exited #{code}" : 'blew was killed')) unless deciding.include?(code)

      check.call(run.output, code)
    end

    # The verdict of a step on its run (nil for a step with no blew command).
    def step_outcome(step, run)
      return outcome(:unknown, 'needs blew nus') unless step.argv

      judge(run, deciding: step.deciding, &step.check)
    end

    # The steps after the scan, on the device it found. The identifier is checked
    # because it is spliced into a blew script. A 2 from one of them could be this
    # host failing to find the device again, so it decides nothing.
    def steps(id)
      raise Error, 'a device identifier is hexadecimal groups' unless /\A#{IDENTIFIER}\z/.match?(id)

      connect = "connect #{id}"
      exec_step = lambda do |name, command, check|
        Step.new(name: name, argv: ['exec', "#{connect}; #{command}"], deciding: [0, 5], check: check)
      end
      [exec_step.call('connect and discover', 'gatt tree', method(:discover_outcome)),
       exec_step.call('write NUS RX', "write -r -f utf8 #{NUS_RX} erxos", method(:write_outcome)),
       exec_step.call('read NUS RX, refused', "read #{NUS_RX}", method(:read_outcome)),
       # The echo needs a subscription open while RX is written, which blew's exec
       # cannot do: its sub ends only at a notification. Switch to `blew nus` once a
       # blew release has it.
       Step.new(name: 'NUS echo', argv: nil, deciding: [], check: nil)]
    end

    def discover_outcome(output, code)
      held = code.zero? && output.upcase.include?(NUS_SERVICE)
      outcome(held ? :passed : :failed, 'the table holds NUS')
    end

    # A service with no handler answers writes Unlikely Error by design
    # (docs/design-bluetooth.md, "The `ble` facet"), so that answer says only that no
    # app serves NUS. blew gives the ATT error only as CoreBluetooth's message, and the
    # match on message text assumes an English locale.
    def write_outcome(output, code)
      return outcome(:passed, 'a handler takes the write') if code.zero?
      return outcome(:unknown, 'Unlikely Error: no handler answered') if output.include?('Unlikely error')

      outcome(:failed, 'the write failed')
    end

    # CoreBluetooth's message for a characteristic without the read property; the
    # same English-locale assumption.
    def read_outcome(output, code)
      outcome(code == 5 && output.include?('not permitted') ? :passed : :failed, 'refuses a read of RX')
    end

    # 0 when a step passed and none failed, 1 when one failed, 3 when none passed.
    def script_exit(outcomes)
      verdicts = outcomes.map(&:verdict)
      return 1 if verdicts.include?(:failed)

      verdicts.include?(:passed) ? 0 : 3
    end
  end
end
