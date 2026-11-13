# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'set'
require 'tmpdir'
require_relative '../../tools/lib/erx/interactive_boot'

# The pure half of `tools/erx boot` (its arguments, the accelerator it picks
# and the QEMU argument vector it plans) and the child handling of its run,
# with a Ruby child standing in for QEMU. Nothing here boots a guest.
class InteractiveBootTest < Minitest::Test
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  def test_no_arguments_ask_for_one_cpu_and_this_hosts_accelerator
    assert_equal Erx::InteractiveBoot::Request.new(accel: nil, cpus: 1, jobs: Erx::InteractiveBoot::DEFAULT_JOBS,
                                                    hostlink: false, without_web: false),
                 Erx::InteractiveBoot.request([])
  end

  def test_options_name_the_accelerator_cpus_and_jobs
    assert_equal Erx::InteractiveBoot::Request.new(accel: 'tcg', cpus: 4, jobs: 2, hostlink: false, without_web: false),
                 Erx::InteractiveBoot.request(%w[--accel tcg --cpus 4 --jobs 2])
  end

  def test_bad_arguments_are_refused_as_usage_errors
    [%w[--cpus 0], %w[--cpus 9], %w[--cpus -1], %w[--cpus two], %w[--accel kvm], %w[--accel], %w[extra],
     %w[--memory-mib 512], %w[--jobs 0], %w[--jobs 65]].each do |arguments|
      assert_raises(OptionParser::ParseError, arguments.join(' ')) { Erx::InteractiveBoot.request(arguments) }
    end
  end

  def test_the_request_leaves_the_callers_arguments_alone
    arguments = %w[--cpus 2].freeze
    Erx::InteractiveBoot.request(arguments)
    assert_equal %w[--cpus 2], arguments
  end

  def test_hvf_is_the_default_where_qemu_offers_it
    assert_equal 'hvf', Erx::InteractiveBoot.default_accel(Set['hvf', 'tcg'])
    assert_equal 'tcg', Erx::InteractiveBoot.default_accel(Set['tcg'])
    assert_equal 'tcg', Erx::InteractiveBoot.default_accel(Set[])
  end

  def test_qemu_runs_on_this_terminal_with_its_monitor_muxed_and_never_reboots
    argv = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'hvf', cpus: 2, image: '/tree/build/image.boot', memory_mib: 512)
    assert_equal 'qemu-system-aarch64', argv.first
    assert_equal 'mon:stdio', argv.fetch(argv.index('-serial') + 1)
    # The console is the first serial line; the second, the host link's UART, is QEMU's null device.
    assert_equal %w[mon:stdio null], argv.each_index.select { |at| argv[at] == '-serial' }.map { |at| argv[at + 1] }
    assert_includes argv, '-no-reboot'
    assert_equal '/tree/build/image.boot', argv.fetch(argv.index('-kernel') + 1)
    assert_equal '2', argv.fetch(argv.index('-smp') + 1)
    assert_equal '512', argv.fetch(argv.index('-m') + 1)
    refute(argv.any? { |word| word.start_with?('file:') })
  end

  # The harness's line, after the word that asks for the host link the plan gives the guest.
  def test_each_accelerator_gets_the_harness_kernel_command_line
    tcg = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'tcg', cpus: 1, image: 'image.boot', memory_mib: 512)
    hvf = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'hvf', cpus: 1, image: 'image.boot', memory_mib: 512)
    word = Erx::QemuPlan::HOSTLINK_WORD
    assert_equal ['-append', "#{word} #{Erx::ProductionImage::Run::COMMAND_LINES.fetch('tcg')}"], tcg.last(2)
    assert_equal ['-append', word], hvf.last(2)
  end

  def test_hostlink_asks_for_the_host_link_and_a_data_medium
    refute Erx::InteractiveBoot.request([]).hostlink
    assert Erx::InteractiveBoot.request(%w[--hostlink]).hostlink
    assert_raises(OptionParser::ParseError) { Erx::InteractiveBoot.request(%w[--hostlink /tmp/socket]) }
  end

  # --without-web builds the website's image from the checked-in site manifest as it
  # stands, so the image's manifest check runs over the file the site ships, into a
  # directory of its own, which a development boot never replaces; without the option
  # the image is the development manifest's. It cannot be combined with --hostlink,
  # whose web view the web domain serves.
  def test_without_web_builds_from_the_site_manifest
    root = File.expand_path('../..', __dir__)
    refute Erx::InteractiveBoot.request([]).without_web
    assert Erx::InteractiveBoot.request(%w[--without-web]).without_web
    assert_raises(OptionParser::ParseError) { Erx::InteractiveBoot.request(%w[--without-web --hostlink]) }
    assert_equal File.binread(File.join(root, PLATFORM.manifest_path)),
                 Erx::InteractiveBoot.manifest_source(root: root, platform: PLATFORM, without_web: false)
    assert_equal File.binread(File.join(root, PLATFORM.site_manifest_path)),
                 Erx::InteractiveBoot.manifest_source(root: root, platform: PLATFORM, without_web: true)
    assert_equal 'config/manifest/qemu-virt-site.txt', PLATFORM.site_manifest_path
    assert_equal Erx::InteractiveBoot::DIRECTORY, Erx::InteractiveBoot.image_directory(without_web: false)
    assert_equal 'build/production-image/site', Erx::InteractiveBoot.image_directory(without_web: true)
    # The website's image is packed for, and boots on, the RAM the website gives it.
    assert_equal 256, Erx::InteractiveBoot.machine(platform: PLATFORM, without_web: true).memory_mib
    assert_equal PLATFORM.memory_mib, Erx::InteractiveBoot.machine(platform: PLATFORM, without_web: false).memory_mib
  end

  # The site manifest is the development manifest without its web and display domains:
  # the development manifest's records less the web domain's six (its share, runtime
  # limits, limits and domain, its relay service and the system domain's facet of it) and
  # the display domain's seven (its share, runtime limits, limits and domain, its window
  # tree's service and display record, and the display unit it holds) are the site's,
  # line for line, except the room the two domains took: the system principal's memory
  # and domains less the two limits' budgets and outer ones and less two, and the root's
  # root_memory, max_domains and max_connections less the same budgets and the display
  # unit's DMA memory, two domains and their system connections' rows. No reference to
  # either domain remains, so the site grants nothing the development image does not and
  # moves with it. Comments and blank lines may differ.
  def test_the_site_manifest_is_the_development_manifest_without_the_web_and_display_domains
    root = File.expand_path('../..', __dir__)
    development = manifest_records(File.binread(File.join(root, PLATFORM.manifest_path)))
    site = manifest_records(File.binread(File.join(root, PLATFORM.site_manifest_path)))
    left_out, kept = development.partition { |record| record.first.match?(/\A[a-z_]+ (?:web|display)\n\z/) }
    kinds = ->(name) { left_out.map(&:first).grep(/ #{name}\n\z/).map { |header| header[/\A[a-z_]+/] } }
    assert_equal %w[share runtime_limits limits domain service facet], kinds.call('web')
    assert_equal %w[share runtime_limits limits unit domain service display], kinds.call('display')
    refute_match(/@(?:share|domain|service)\.(?:web|display)$/, site.join)
    room = %w[web display].sum do |name|
      limits = left_out.find { |record| record.first == "limits #{name}\n" }.join
      Integer(limits[/^  memory ([0-9]+)$/, 1], 10) + Integer(limits[/^  outer ([0-9]+)$/, 1], 10)
    end
    dma = PLATFORM.record.fetch('units').find { |unit| unit.fetch('key') == 'display' }
                  .fetch('devices').sum { |device| device.fetch('dma_memory') }
    assert_equal kept.map(&:first), site.map(&:first), 'config/manifest/qemu-virt-site.txt has other records'
    root = kept.find { |record| record.any?(/\A  max_domains /) }.first
    assert_equal [["principal system\n", 'domains', -2], ["principal system\n", 'memory', -room],
                  [root, 'max_connections', -2],
                  [root, 'max_domains', -2],
                  [root, 'root_memory', -(room + dma)]].sort,
                 figure_changes(kept, site).sort
  end

  # A manifest's records, each the list of its lines, header first, without comments
  # and blank lines.
  def manifest_records(text)
    text.lines.reject { |line| line.start_with?('#') || line.strip.empty? }.slice_before(/\A\S/).to_a
  end

  # Where two lists of the same records differ, each as [header, field, change]: the
  # lines must be one numeric field each, the same field on both sides.
  def figure_changes(before, after)
    before.zip(after).flat_map do |old, new|
      assert_equal old.size, new.size, "#{old.first.strip} has other lines"
      old.zip(new).reject { |left, right| left == right }.map do |left, right|
        field, figure = left.match(/\A {2}([a-z_]+) ([0-9]+)\n\z/)&.captures
        changed = field && right.match(/\A {2}#{field} ([0-9]+)\n\z/)
        assert changed, "#{old.first.strip}: #{right.inspect} in place of #{left.inspect}"
        [old.first, field, Integer(changed[1], 10) - Integer(figure, 10)]
      end
    end
  end

  # With a link, the second serial line listens on its socket without waiting
  # for a client, and the medium is the guest's one disk; the console stays on
  # this terminal.
  def test_a_link_puts_the_host_link_on_its_socket_and_attaches_the_medium
    link = Erx::InteractiveBoot::Link.new(socket: '/tree/build/link/socket', medium: '/tree/build/medium.img')
    argv = Erx::InteractiveBoot.argv(platform: PLATFORM, accel: 'hvf', cpus: 1, image: '/tree/build/image.boot', memory_mib: 512, link: link)
    assert_equal ['mon:stdio', 'unix:/tree/build/link/socket,server=on,wait=off'],
                 argv.each_index.select { |at| argv[at] == '-serial' }.map { |at| argv[at + 1] }
    drives = argv.each_index.select { |at| argv[at] == '-drive' }.map { |at| argv[at + 1] }
    assert_equal ['file=/tree/build/medium.img,format=raw,if=none,id=disk0'], drives
    assert_includes argv, '-no-reboot'
  end

  def test_the_web_command_names_the_socket_as_one_shell_word
    assert_equal '/tree/tools/erx web --socket /tree/build/link/socket',
                 Erx::InteractiveBoot.web_command('/tree/tools/erx', '/tree/build/link/socket')
    assert_equal '/my\\ tree/tools/erx web --socket /my\\ tree/socket',
                 Erx::InteractiveBoot.web_command('/my tree/tools/erx', '/my tree/socket')
  end

  def test_run_returns_the_childs_exit_status
    assert_equal 3, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'exit 3'])
    assert_equal 0, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'exit 0'])
  end

  def test_a_child_ended_by_a_signal_is_a_failure
    assert_equal 1, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'Process.kill("KILL", Process.pid)'])
  end

  # An interrupt that reaches tools/erx while QEMU runs must not leave QEMU
  # running: the child writes its pid, the test interrupts the waiting run,
  # and afterwards no process has that pid.
  def test_an_interrupt_stops_the_child_before_it_propagates
    pid = interrupted_child(body: 'sleep 60', interrupts: 1)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  # A child that ignores SIGTERM, interrupted twice: the second interrupt
  # waits for the cleanup, which kills the child once its time is up.
  def test_a_second_interrupt_cannot_cut_the_stop_short
    pid = interrupted_child(body: 'trap("TERM") {}; sleep 60', interrupts: 2)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  private

  # Runs a Ruby child with body under InteractiveBoot.run, raises Interrupt
  # in this thread interrupts times once the child has written its pid,
  # checks the interrupt propagated, and returns the child's pid.
  def interrupted_child(body:, interrupts:)
    Dir.mktmpdir('erx-interactive-boot-') do |directory|
      pid_file = File.join(directory, 'pid')
      child = [RbConfig.ruby, '-e', "File.write(ARGV.fetch(0), Process.pid.to_s); #{body}", pid_file]
      waiter = Thread.new(Thread.current) do |main|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        sleep(0.05) until File.size?(pid_file) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.2) # the trap, where there is one, is set right after the write
        interrupts.times do
          main.raise(Interrupt)
          sleep(0.2)
        end
      end
      begin
        assert_raises(Interrupt) { Erx::InteractiveBoot.run(child, stop_seconds: 1) }
      ensure
        waiter.join(35) || waiter.kill
      end
      pid = Integer(File.read(pid_file))
      # A regressed stop leaves the child running: the caller's assertion
      # fails, and the child still does not outlive the test.
      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
      return pid
    end
  end
end
