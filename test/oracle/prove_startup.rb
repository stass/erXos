#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'rbconfig'
require_relative '../../tools/lib/erx/oracle_container'

options = { root: File.expand_path('../..', __dir__) }
parser = OptionParser.new do |arguments|
  arguments.on('--context NAME') { |value| options[:context] = value }
  arguments.on('--root DIRECTORY') { |value| options[:root] = value }
  arguments.on('--child') { options[:child] = true }
  arguments.on('--memory-mib N', Integer) { |value| options[:memory_mib] = value }
end
begin
  remaining = parser.parse(ARGV)
  raise OptionParser::MissingArgument, '--context' unless options[:context]
  raise OptionParser::InvalidArgument, 'unexpected arguments' unless remaining.empty?
  root = options.fetch(:root)
  if options[:child]
    resources = Erx::OracleContainer::RESOURCES
    if options[:memory_mib]
      resources = resources.merge('memory_bytes' => options.fetch(:memory_mib) * 1024**2)
    end
    adapter = Erx::OracleContainer.new(root: root, context: options.fetch(:context), resources: resources)
    result = adapter.run('emulator', flavour: 'emu', jobs: 4, deadline: 600,
                         test_suite: 'binary_SUITE', testcase: 'deep_bitstr_lists')
    unless result.fetch('container').fetch('guest')['operator_startup_marker'] == false
      raise Erx::Error, 'isolated oracle did not prove absence of parent startup execution'
    end
    File.write(File.join(root, 'build/oracle/linux/startup-proof.json'),
               JSON.pretty_generate('state' => 'completed', 'suite_report' => result.fetch('report'),
                                    'parent_proxy_and_startup_ignored' => true) + "\n")
  else
    parent = File.join(root, 'build/oracle/linux/startup-fixtures')
    FileUtils.mkdir_p(parent)
    directory = Dir.mktmpdir('parent-', parent)
    home = File.join(directory, 'home')
    xdg = File.join(directory, 'xdg')
    FileUtils.mkdir_p(File.join(xdg, 'erlang'))
    Dir.mkdir(home)
    poison = 'file:write_file("/tmp/erx-oracle/operator-startup-executed", <<"unexpected parent startup">>).' + "\n"
    File.write(File.join(home, '.erlang'), poison)
    File.write(File.join(xdg, 'erlang/.erlang'), poison)
    operator_config = ENV['DOCKER_CONFIG'] || File.join(Dir.home, '.docker')
    environment = {
      'HOME' => home, 'XDG_CONFIG_HOME' => xdg, 'DOCKER_CONFIG' => operator_config,
      'DOCKER_HOST' => 'tcp://192.0.2.1:2375', 'DOCKER_CONTEXT' => 'must-not-be-selected',
      'HTTP_PROXY' => 'http://192.0.2.1:9', 'HTTPS_PROXY' => 'http://192.0.2.1:9',
      'ALL_PROXY' => 'http://192.0.2.1:9', 'ERL_ROOTDIR' => '/unexpected-parent-runtime',
      'ERL_FLAGS' => '-eval erlang:halt(77).', 'ERL_AFLAGS' => '-eval erlang:halt(78).'
    }
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    selection = options[:memory_mib] ? ['--memory-mib', options.fetch(:memory_mib).to_s] : []
    runner.run([RbConfig.ruby, __FILE__, '--child', '--root', root, '--context', options.fetch(:context), *selection],
               name: 'oracle-startup-proof', deadline: 3600, env: environment)
  end
  Erx::Terminal.puts('isolated oracle parent startup and proxy proof passed')
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
rescue Erx::Error, SystemCallError => error
  Erx::Terminal.puts(error.message)
  exit 1
end
