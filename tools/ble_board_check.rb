#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs the scripted part of the Bluetooth board checklist
# (docs/design-bluetooth.md, "On the board") from a macOS host against a board
# that advertises under --name, through blew, a macOS Bluetooth LE command-line
# tool on the PATH. One scan finds the device that advertises exactly that name;
# every later step is one blew run on a connection of its own to that device's
# identifier (the scan makes no connection), so each also checks a
# reconnection. CoreBluetooth keeps GAP's and GATT's services to itself, so the
# steps work on Nordic's UART service (abi/gatt/nus.txt). Each step prints passed, failed, or unknown: unknown when
# blew timed out, could not use Bluetooth, was missing or was given bad arguments,
# or when what the step needs (decision 7's bleuart service, a blew command) is
# missing, never a guess; Erx::BleBoardCheck holds the verdicts. Logs of every blew
# run go in --logs. Exits 0 when a step passed and none failed, 1 when a step
# failed, 3 when none passed, 2 on bad usage or when it cannot run blew or keep its logs.
#
#   ruby tools/ble_board_check.rb --name erxos --logs DIR

require 'optparse'
require_relative 'lib/erx/ble_board_check'
require_relative 'lib/erx/runner'

# Runs blew once. A run killed on its deadline or by a signal has no exit code.
def blew(runner, step_name, argv, timeout)
  record = begin
    runner.run(['blew', '--timeout', timeout.to_s, '--out', 'kv', *argv],
               name: "ble-#{step_name.downcase.tr(' ,', '-')}", deadline: timeout * 3)
  rescue Erx::CommandError => error
    error.result
  end
  output = File.binread(record.fetch('log')).force_encoding(Encoding::UTF_8).scrub
  Erx::BleBoardCheck::Run.new(output: output, exit_code: record['state'] == 'timed_out' ? nil : record['exit_status'])
end

# One bleuart session: blew nus reads the typed lines from a named pipe in the logs,
# which a thread writes, each line after its pause, and the line's answers go to the
# run's log. A blew that ends early leaves the thread a broken pipe.
def nus_session(runner, logs, id, name, typed, timeout)
  fifo = File.join(logs, "#{name}.in")
  File.unlink(fifo) if File.exist?(fifo)
  File.mkfifo(fifo, 0o600)
  writer = Thread.new do
    File.open(fifo, 'wb') do |pipe|
      typed.each do |line|
        sleep(line.pause)
        pipe.write(line.text)
        pipe.flush
      end
    end
  rescue Errno::EPIPE
    nil
  end
  argv = ['blew', '--timeout', timeout.to_s, *Erx::BleBoardCheck.nus_argv(id, linger: NUS_LINGER)]
  record = begin
    runner.run(argv, name: name, deadline: (timeout * 3) + typed.sum(&:pause) + NUS_LINGER, stdin: fifo)
  rescue Erx::CommandError => error
    error.result
  end
  output = File.binread(record.fetch('log')).force_encoding(Encoding::UTF_8).scrub
  Erx::BleBoardCheck::Run.new(output: output, exit_code: record['state'] == 'timed_out' ? nil : record['exit_status'])
ensure
  writer&.kill
  File.unlink(fifo) if fifo && File.exist?(fifo)
end

def report(step_name, outcome)
  puts "#{outcome.verdict}: #{step_name} (#{outcome.detail})"
  outcome
end

# Seconds blew nus listens after a session's last line.
NUS_LINGER = 5

USAGE = 'usage: ruby tools/ble_board_check.rb --name NAME --logs DIR [--timeout SECS]'
options = { timeout: 15 }
begin
  OptionParser.new(USAGE) do |flags|
    flags.on('--name NAME', 'the name the board advertises') { |value| options[:name] = value }
    flags.on('--logs DIR', 'where the logs of the blew runs go') { |value| options[:logs] = File.expand_path(value) }
    flags.on('--timeout SECS', Integer, 'blew\'s timeout for each step') do |value|
      raise OptionParser::InvalidArgument, value.to_s unless value.between?(1, 600)

      options[:timeout] = value
    end
  end.parse!
rescue OptionParser::ParseError => error
  warn("#{error.message}\n#{USAGE}")
  exit 2
end
options[:name] = options[:name]&.dup&.force_encoding(Encoding::UTF_8)
unless options[:name]&.valid_encoding? && !options[:name].empty? && options[:logs] && ARGV.empty?
  warn(USAGE)
  exit 2
end

begin
  runner = Erx::Runner.new(owner_root: File.dirname(options[:logs]), log_dir: options[:logs])
  # blew's own --name filter keeps the room's other devices out of the logs; the
  # exact match of the name is the library's.
  scan = Erx::BleBoardCheck.scan_result(blew(runner, 'scan', ['scan', '-n', options[:name]], options[:timeout]), options[:name])
  outcomes = [report('scan', scan.outcome)]
  if scan.id
    outcomes += Erx::BleBoardCheck.steps(scan.id).map do |step|
      report(step.name, Erx::BleBoardCheck.step_outcome(step, blew(runner, step.name, step.argv, options[:timeout])))
    end
    first = nus_session(runner, options[:logs], scan.id, 'bleuart-session', Erx::BleBoardCheck::SESSION, options[:timeout])
    second = nus_session(runner, options[:logs], scan.id, 'bleuart-reconnection', Erx::BleBoardCheck::RECONNECTION,
                         options[:timeout])
    outcomes += Erx::BleBoardCheck.bleuart_outcomes(first, second).map { |name, outcome| report(name, outcome) }
  else
    outcomes << report('the steps after the scan', Erx::BleBoardCheck::NO_DEVICE)
  end
  exit Erx::BleBoardCheck.script_exit(outcomes)
rescue Erx::Error => error
  warn(Erx::Terminal.escape(error.message))
  exit 2
end
