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
require_relative 'lib/erx/boot_partition'
require 'tmpdir'
require_relative 'lib/erx/data_volume'
require_relative 'lib/erx/interactive_boot'
require_relative 'lib/erx/output_directory'
require_relative 'lib/erx/site'

root = File.expand_path('..', __dir__)
options = { image: File.join(root, Erx::InteractiveBoot::SITE_DIRECTORY, 'image.boot'),
            card: File.join(root, 'build/production-image/raspi4b', Erx::BootPartition::IMAGE), card_record: nil,
            out: File.join(root, 'build/site'), v64: nil, serve: nil, source: nil }
card_given = false
parser = OptionParser.new do |flags|
  flags.banner = 'Usage: ruby tools/build_site.rb [--v64 DIR] [--image PATH] [--card PATH] [--card-record PATH] ' \
                 '[--no-card] [--source REF] [--out DIR] [--serve PORT]'
  flags.on('--v64 DIR', "a v64 tree an earlier run built (default: build the fetched, pinned v64 in #{Erx::SiteV64::STAGING})") do |path|
    options[:v64] = File.expand_path(path)
  end
  flags.on('--image PATH', "erXos boot image (default: the website's, which tools/erx boot --without-web builds)") do |path|
    options[:image] = File.expand_path(path)
  end
  flags.on('--card PATH', "the Raspberry Pi 4's card (default: the one make pack PLATFORM=raspi4b builds)") do |path|
    options[:card] = File.expand_path(path)
    card_given = true
  end
  flags.on('--card-record PATH', "the card's build record (default: the card's path with .receipt.json added)") do |path|
    options[:card_record] = File.expand_path(path)
    card_given = true
  end
  flags.on('--no-card', 'build the page without the Raspberry Pi 4 section, for a local preview; the site workflow never uses it') do
    options[:no_card] = true
  end
  flags.on('--source REF', 'full commit the image and card were built from, as the card\'s record names it (default: this tree\'s HEAD)') do |ref|
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
  raise OptionParser::InvalidOption, '--no-card with --card or --card-record' if options[:no_card] && card_given
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
  # The page's installation: a fresh data volume, formatted in a directory of its own.
  disk = Dir.mktmpdir('site-volume-', Erx::OutputDirectory.prepare(root:, path: File.join(root, 'build/site-volume'))) do |directory|
    volume = Erx::DataVolume.format(root:, runner:, directory:, data_sectors: Erx::Site.data_sectors)
    Erx::Site.fresh_medium(volume: File.binread(volume.path))
  end
  card = options[:no_card] ? nil : options.fetch(:card)
  card_record = card && (options[:card_record] || "#{card}.receipt.json")
  plan = Erx::Site.inventory(root:, v64:, image: options.fetch(:image), card:, card_record:, source:, disk:)
  manifest = Erx::Site.publish(plan, out: options.fetch(:out), runner:)
  card_summary = manifest[:card] ? "card #{manifest.dig(:card, :compressed_bytes)} bytes compressed" : 'no card'
  puts "Site: #{options.fetch(:out)} (image #{manifest.fetch(:bytes)} bytes, " \
       "#{manifest.fetch(:compressed_bytes)} compressed; disk #{manifest.dig(:disk, :capacity)} bytes, " \
       "#{manifest.dig(:disk, :bytes)} published; " \
       "#{card_summary}; " \
       "source #{source.ref})"
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
