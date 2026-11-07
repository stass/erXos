#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Assembles the website in build/site (see site/README.md) and, with
# --serve, serves it on 127.0.0.1. Exits 0 on success or when the server is
# interrupted, 1 on failure, 2 on a usage error and 130 when a build is
# interrupted.

require 'optparse'
require_relative 'lib/erx/runner'
require_relative 'lib/erx/site'

root = File.expand_path('..', __dir__)
options = { image: File.join(root, 'build/production-image/interactive/image.boot'),
            out: File.join(root, 'build/site'), v64: nil, serve: nil, source: nil }
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/build_site.rb [--v64 DIR] [--image PATH] [--source REF] [--out DIR] [--serve PORT]'
  flags.on('--v64 DIR', "a v64 tree an earlier run built (default: build the fetched, pinned v64 in #{Erx::SiteV64::STAGING})") do |path|
    options[:v64] = File.expand_path(path)
  end
  flags.on('--image PATH', 'erXos boot image (default: the interactive production image)') do |path|
    options[:image] = File.expand_path(path)
  end
  flags.on('--source REF', 'release tag or commit the image was built from (default: this tree\'s HEAD)') do |ref|
    options[:source] = ref
  end
  flags.on('--out DIR', 'output directory (default: build/site)') { |path| options[:out] = File.expand_path(path) }
  flags.on('--serve PORT', Integer, 'serve the result on 127.0.0.1:PORT') { |port| options[:serve] = port }
  flags.on('--help') do
    puts flags
    exit 0
  end
end

begin
  parser.parse!
  raise OptionParser::NeedlessArgument, ARGV.join(' ') unless ARGV.empty?
rescue OptionParser::ParseError => error
  warn error.message
  warn parser.banner
  exit 2
end

begin
  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
  ref = options[:source] ||
        File.read(runner.run(%W[git -C #{root} rev-parse HEAD], name: 'site-head', deadline: 30).fetch('log')).strip
  source = Erx::Site.source(ref)
  v64 = options[:v64] || Erx::SiteV64.build(root:, runner:)
  plan = Erx::Site.inventory(root:, v64:, image: options.fetch(:image), source:)
  manifest = Erx::Site.publish(plan, out: options.fetch(:out))
  puts "Site: #{options.fetch(:out)} (image #{manifest.fetch(:bytes)} bytes, " \
       "#{manifest.fetch(:compressed_bytes)} compressed, source #{source.ref})"
  if options[:serve]
    options[:serving] = true
    Erx::Site.serve(dir: options.fetch(:out), port: options.fetch(:serve))
  end
rescue Erx::Error => error
  Erx::Terminal.puts(error.message)
  exit 1
rescue SystemCallError => error
  Erx::Terminal.puts("build_site: #{error.message}")
  exit 1
rescue Interrupt
  # Stopping the server is the normal end; interrupting a build is not.
  exit(options[:serving] ? 0 : 130)
end
