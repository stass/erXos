# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/web_build'
require_relative '../../tools/lib/erx/web_inventory'
require_relative '../../tools/lib/erx/web_server'

# The client's browser tests (docs/design-web.md, "Verification and testing";
# web/test/browser/): the client built as `make web` builds it, served by the
# host tool's own front end on loopback with the headers it writes on every
# file, and loaded in the Chromium deps.lock pins, which `tools/erx fetch`
# verified. No machine is behind the front end: Playwright's WebSocket
# routing plays the machine's side in the page (web/test/browser/machine.ts).
# Only macOS on arm64 has that Chromium; the check names this file as not run
# on any other host (Runtime::BROWSER_TESTS).
class WebBrowserTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CHROMIUM = 'chromium-headless-shell'
  # The policy test's probes (web/test/browser/policy.spec.ts), served beside the client's files.
  PROBES = %w[probe.html probe-eval.js].freeze
  DEADLINE = 600

  # The front end's machine end when there is no machine: no facet, so an
  # upgrade that reached the server would be refused. None does: every
  # WebSocket stays in the page.
  class NoMachine
    def open? = false

    def open = raise(Erx::Web::Relay::Down, 'no machine: the browser tests play it in the page')

    def messages = []

    def close(_number) = nil
  end

  def test_the_client_in_chromium
    Dir.mktmpdir('erx-web-browser') do |directory|
      stage = File.join(directory, 'stage')
      client = Erx::WebBuild.build(root: ROOT, runner: runner, stage: stage, output: File.join(directory, 'web'))
      serving(served(client, probes: File.join(stage, 'test/browser'))) do |origin|
        runner.run(['node', 'node_modules/@playwright/test/cli.js', 'test', '--config', 'test/browser/playwright.config.ts'],
                   name: 'web-browser', deadline: DEADLINE, chdir: stage,
                   env: Erx::WebBuild::OFFLINE_ENV.merge('ERX_WEB_ORIGIN' => origin, 'ERX_CHROMIUM' => chromium,
                                                         'ERX_WEB_POLICY' => Erx::Web::Http::POLICY,
                                                         'ERX_BROWSER_OUTPUT' => File.join(directory, 'results'),
                                                         'PLAYWRIGHT_BROWSERS_PATH' => File.join(directory, 'no-browsers')))
      end
    end
  end

  private

  def runner = @runner ||= Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))

  # The headless Chromium of deps.lock's pin, as `tools/erx fetch` unpacked it.
  def chromium
    tree = Erx::Dependencies.new(root: ROOT, runner: runner).fetched_tree(CHROMIUM)
    File.join(tree, 'chrome-headless-shell')
  end

  # The client's files and the probes in directory probes, as the front end's inventory.
  def served(client, probes:)
    built = Erx::Web::Inventory.load(client)
    Erx::Web::Inventory.new([*built.paths.map { |path| [path, built.file(path).bytes] },
                             *PROBES.map { |name| [name, File.binread(File.join(probes, name))] }])
  end

  # Runs the front end on loopback while the block runs, with the origin a browser loads it from.
  def serving(inventory)
    server = Erx::Web::Server.new(relay: NoMachine.new, inventory: inventory, out: ->(_line) {})
    thread = Thread.new { server.serve }
    yield "http://127.0.0.1:#{server.port}"
  ensure
    # A server thread that died has shut itself down; joining it raises its error.
    server&.stop if thread&.alive?
    thread&.join
  end
end
