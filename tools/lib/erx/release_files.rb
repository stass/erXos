# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'asn1_specifications'
require_relative 'dependency_status'
require_relative 'domain_image_apps'
require_relative 'domain_startup'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'manifest_frontend'
require_relative 'oracle'
require_relative 'runtime'
require_relative 'trust_store'

module Erx
  # The system release's files as entries for Pack#build: the beams, application files
  # and headers of the OTP applications the runtime builds (Runtime::APPLICATIONS) and of
  # erXos's own (ErlangApps), with a start.boot of their own that starts them, as
  # docs/design-runtime.md's Configuration does, or only loads them (LOAD_ONLY). The
  # headers ship so that code compiled on erXos finds them through include_lib, as on
  # stock. The hosted archive (Release) and the native one (ProductionImage) both take
  # their files from here, each from its own build of the applications, and
  # `+deterministic` makes those builds the same bytes. The one domain release (domain)
  # is laid out the same way under domains/erxos/, from the same builds, without the
  # system mark: each file of the applications its boot scripts name, once, and a boot
  # script bin/<name>.boot for each name (domain_boot), whose release file lists only
  # that script's applications. A release that holds public_key also carries the image's
  # trust store as its priv/cacerts.pem (TrustStore).
  class ReleaseFiles
    # In the release file's order, each after the applications it depends on.
    APPLICATIONS = [*Runtime::APPLICATIONS, *ErlangApps::APPLICATIONS].freeze
    # Loaded, not started: the release file gives them start type load, so the boot
    # script loads their .app files and puts them on the code path, and the shell has
    # c:c and dbg, but nothing of theirs runs at boot. Started, runtime_tools would
    # start runtime_tools_sup and its ttb_autostart.
    LOAD_ONLY = %w[compiler runtime_tools].freeze
    # A name here that the release does not ship would leave that application started.
    raise Error, "LOAD_ONLY names what the release does not ship: #{LOAD_ONLY - APPLICATIONS}" unless
      (LOAD_ONLY - APPLICATIONS).empty?
    # A domain's own applications, which every release only loads, so that none runs in
    # the system domain and none starts before its domain's facets: the session
    # template's arguments start erx_session with -eval, which runs once init has them
    # (docs/design-runtime.md, edit 65), and the app template's start erx_app, once the
    # ready answer has also brought the app's record (docs/design-packaging.md,
    # "Starting an app"). The system release ships erx_session (SYSTEM_APPLICATIONS)
    # and not erx_app, which only the app script holds. erx_wifi, the WiFi domain's
    # (docs/design-wifi.md, "The WiFi domain"), is only loaded until the domain's
    # station starts it once it holds its facets. erx_ntpd, the ntpd session's
    # (docs/design-time.md, "Who does what"), is started by the ntpd template's -eval,
    # and erx_bleuart, the bleuart session's (docs/design-bluetooth.md, "The console"),
    # by the bleuart template's.
    DOMAIN_ONLY = %w[erx_session erx_app erx_wifi erx_ntpd erx_bleuart].freeze
    raise Error, "DOMAIN_ONLY names what the release does not ship: #{DOMAIN_ONLY - APPLICATIONS}" unless
      (DOMAIN_ONLY - APPLICATIONS).empty?
    # OTP's applications that only the domains' runtime images run (DomainImageApps).
    # Neither the system release nor the hosted runtime, which links neither of their
    # NIFs, can run them, so the hosted oracle's tree leaves them out
    # (OracleHosted.application_files) and a suite there skips them as on a stock OTP
    # built without crypto. Every release only loads them (release_entry): the boot script
    # puts them on the code path and starts nothing of theirs, so a domain runs no ssh
    # supervisor until a program of its own calls ssh:start/0 (docs/design-ssh.md,
    # "Stages"), and none runs ssl's or inets' supervisors until a program starts them.
    DOMAIN_IMAGE_ONLY = DomainImageApps::APPLICATIONS
    # Every application a release only loads; it starts each other one it holds
    # (started?).
    LOADED = [*LOAD_ONLY, *DOMAIN_ONLY, *DOMAIN_IMAGE_ONLY].freeze
    # The applications of LOADED a script starts all the same, by the script's name. The
    # bt script starts crypto, which erx_bt requires, so that it can start erx_bt before
    # init's ready report: erx_bt's start names the mint of ble, which the report ends
    # (docs/design-bluetooth.md, "The Bluetooth domain"). crypto runs no process, so its
    # start only marks it started.
    SCRIPT_STARTS = { 'bt' => %w[crypto].freeze }.freeze

    NAME = 'erxos'
    BOOT_DEADLINE = 120
    # The imported trees the release's files come from, as a pack registers them
    # (PackProvenance): OTP for the applications, and the trust store's roots for
    # public_key's cacerts.pem (trust_store).
    IMPORTS = { 'otp' => DependencyStatus::PERMANENT, TrustStore::DIRECTORY => DependencyStatus::PERMANENT }.freeze
    # A file of the release: its path in the archive, the built file and what it came from.
    ReleaseFile = Data.define(:path, :artifact, :sources)

    # Which release the files are: its name in its release files, the prefix its paths
    # take in the archive, its applications in the release file's order, whether its
    # files carry the system mark, which only the system release's do
    # (docs/design-kernel.md, "The boot image"), and its boot scripts: for each name,
    # bin/<name>.boot, whose release file names the applications given, in that order.
    Release = Data.define(:name, :prefix, :applications, :system, :boots)
    # What every domain boots: kernel and stdlib, which a release boots through, erx
    # and erx_files, whose processes erXos's kernel_sup and kernel_safe_sup start in every
    # domain (its watchdog's child, its namespace table, /tmp and /proc), and
    # erx_net_client, the socket backends inet's default backend names, which every erXos
    # domain runs (docs/design-network-stack.md, "Modules"). Its `grant` key has no
    # default: a domain whose startup arguments set none answers every socket call with
    # {error, eacces} and runs no resolver loader.
    DOMAIN_BASE = %w[kernel stdlib erx erx_files erx_net_client].freeze
    # What every session boots (docs/design-programs.md, "The command server"): the base
    # every domain boots and erx_session, the session's supervisor, with the command
    # shell it depends on. erx_session_sup starts the session's pipe server and terminal
    # relay, and the design places the command server under it too. Every session
    # template's script takes it whole, the session script and the app script alike, so
    # no session domain lacks the servers a program needs.
    SESSION_BASE = [*DOMAIN_BASE, 'erx_shell', 'erx_session'].freeze
    # The applications the system release ships, in release order: an allow-list, so an
    # application reaches the system domain only by being named here: OTP's, the base
    # every domain boots, the applications the system domain runs, and erx_session, which
    # it ships and never starts (DOMAIN_ONLY). The base's erx_net_client is the socket
    # backends, not the stack: the system domain holds no `net` facet and its startup sets
    # no `grant` key, so every socket call there answers {error, eacces}.
    # Every other application is a domain boot script's alone (RELEASE_SCRIPTS), and one
    # in neither fails the load (check_released).
    SYSTEM_APPLICATIONS = %w[kernel stdlib compiler runtime_tools erx erx_files erx_net_client erx_code erx_uart erx_rtc
                             erx_pins erx_domain erx_starter erx_shell erx_session].freeze
    raise Error, "SYSTEM_APPLICATIONS names what the runtime does not build: #{SYSTEM_APPLICATIONS - APPLICATIONS}" unless
      (SYSTEM_APPLICATIONS - APPLICATIONS).empty?
    raise Error, 'SYSTEM_APPLICATIONS is not in release order (APPLICATIONS)' unless
      SYSTEM_APPLICATIONS == APPLICATIONS & SYSTEM_APPLICATIONS
    # The system domain's runtime links neither NIF, so it could not run them.
    raise Error, "SYSTEM_APPLICATIONS names what only a domain's runtime image runs: #{DOMAIN_IMAGE_ONLY & SYSTEM_APPLICATIONS}" unless
      (DOMAIN_IMAGE_ONLY & SYSTEM_APPLICATIONS).empty?
    SYSTEM = Release.new(name: NAME, prefix: 'system/', applications: SYSTEM_APPLICATIONS, system: true,
                         boots: { 'start' => SYSTEM_APPLICATIONS }.freeze)
    # The build's release scripts table: each domain boot script's applications under its
    # name, which a domain row's `release @artifact.NAME` names (docs/design-fiasco.md,
    # "The production image"), so two rows naming one script cannot disagree on what it
    # boots, and a name the table does not hold is refused (ProductionImage.domain_boot).
    # What a script adds to DOMAIN_BASE and the system release does not ship stays out of
    # the system domain:
    # * erts, the base alone (DOMAIN_BASE): the script of a domain that runs only what
    #   every domain boots, as the medium boot's configured domain and the native domain
    #   tests' domains do (MediumBoot, NativeDomain);
    # * session, a principal's session domain (docs/design-domains.md, "Principals,
    #   sessions and quotas"): the session's line to the web domain (docs/design-web.md,
    #   "Views on the line"), which must be up before init's ready report names it, so the
    #   script starts it; and asn1, crypto, public_key, ssh, ssl and inets
    #   (DOMAIN_IMAGE_ONLY), which it only loads, so that a principal can run OTP's ssh
    #   daemon in its own session (docs/design-ssh.md, "Stages", stage 1) and fetch over
    #   HTTPS (docs/design-crypto.md, "Releases"), and no session runs ssh's supervisors
    #   unasked. A session template's arguments set the base's network client's `grant`
    #   key when it is granted the network. It also starts the client side of the display
    #   (DomainStartup::DISPLAY_CLIENT): a session template may hold a display's grant
    #   (root's display_root), and its programs' window buffers come from erx_win's
    #   allocator, erx_pixels, which runs in every release that holds one
    #   (docs/design-display.md, "The pixel area"; property 18);
    # * storage: the block driver, littlefs's volume (docs/design-stopgap.md, "littlefs
    #   in the storage domain") and F2FS's codec (docs/design-f2fs.md), so no system
    #   domain loads the driver of a device the manifest gives the storage domain,
    #   and none reads its windows or parses a volume;
    # * network: the network stack, started permanent, so the stack's end ends the network
    #   domain (docs/design-network-stack.md, "The process tree"); the system domain parses
    #   no network input and holds no code that reaches a `net` grant, which it may not hold
    #   (docs/design-system.md, property 15);
    # * web: the web front end (docs/design-web.md, "Overview"), since the system domain
    #   decodes no web protocol message;
    # * display: the pixel primitives, the display side of the window system and the
    #   drivers, which start the screen (docs/design-display.md, "Overview"), so no
    #   system domain loads the driver of a device the manifest gives the display domain;
    # * client, a domain that holds a display's grant: the pixel primitives, the client
    #   side, erx_win, and the widget toolkit, erx_ui, which it starts, so its allocator of
    #   pixel areas and its widget servers run there and in neither the system domain nor
    #   the display domain (G9, DisplayRelease), and the desktop's programs, erx_desk
    #   (docs/design-desktop-programs.md), which draw through it.
    #   No manifest names it: it is the client side's release, which DisplayRelease
    #   reads, and a client domain's own script takes the same applications.
    # * ssh, the SSH domain's (docs/design-ssh.md, "The SSH domain"): asn1, crypto,
    #   public_key and ssh (docs/design-ssh.md lists no more). Only this script, session's,
    #   app's and wifi's name crypto, so no other domain's script loads it; a domain boots
    #   in interactive mode, so it can still load any application of the one domain
    #   release on a call (docs/design-fiasco.md, `domains/erxos/...`). No manifest names
    #   it; the native domain tests boot it (NativeDomain).
    # * app, an app's session, which the app template boots (docs/design-packaging.md,
    #   "The apps row"): the client side of the display as client's without the desktop's
    #   programs (erx_desk), compiler (LOAD_ONLY), which an
    #   application an app ships may name, as Elixir's elixir does, so the app's start
    #   (application:ensure_all_started/2) finds it, asn1, crypto, public_key, ssl and inets,
    #   which it only loads, for an app's HTTPS requests (docs/design-crypto.md,
    #   "Releases"), and erx_app (DOMAIN_ONLY), which the template's -eval starts and
    #   which mounts the app's package at /app and starts what it declares. Its .app
    #   file names erx_session, since the design starts a native app's program through
    #   the session's servers. It also takes the Bluetooth client, erx_bt_client, a
    #   library, for an app granted `ble` (docs/design-bluetooth.md, "The client").
    # * usb, the USB domain's (docs/design-usb.md, "Domains and authority"): the USB
    #   stack, erx_usb, so no other domain parses what a USB device writes, and erx_blk,
    #   a library application, whose erx_blk_usb is a medium's block transport. The script
    #   starts it, and its supervisor the places and the input tree's mint, which must name
    #   itself before init's ready report; the row's -eval adds the controllers once the
    #   ready answer brings the pci facet (docs/design-usb.md, "The rows"), so no other
    #   domain's script serves usb_input. QEMU virt's
    #   development manifest names it for its USB domain, which the usb QEMU suite boots
    #   (UsbBoot).
    # * bt, the Bluetooth domain's (docs/design-bluetooth.md, "The Bluetooth domain"): the
    #   Bluetooth stack, erx_bt, so no other domain parses what a controller writes, and
    #   crypto, which its Security Manager calls, both started (SCRIPT_STARTS), so that
    #   erx_bt names the mint of ble before init's ready report; the row's -eval starts
    #   the rest of the stack. QEMU virt's Bluetooth suite's manifest names it (BtDomain),
    #   and the Raspberry Pi 4's development manifest for its Bluetooth domain.
    # * pcie, the PCIe domain's (docs/design-pcie.md, "The PCIe domain"): the enumerator,
    #   erx_pcie, so no other domain parses what a function writes to its configuration
    #   space. The pcie QEMU suite's manifest names it (Erx::PcieDomain).
    # * wifi, the WiFi domain's (docs/design-wifi.md, "The WiFi domain"): crypto, which
    #   the supplicant's key arithmetic calls, and erx_wifi (DOMAIN_ONLY), both only
    #   loaded. No manifest names it; it exists because check_released requires a
    #   release for erx_wifi.
    # * media, the media domain's (docs/design-drives.md, "Manifest rows"): FAT's read
    #   core, erx_fat, and the drives' readers, erx_media, never erx_storage or erx_blk;
    #   QEMU virt's development manifest names it as the holder of the USB domain's drive.
    # * ntpd, the network time client's session (docs/design-time.md, "Who does what"):
    #   erx_ntpd, which the ntpd template's -eval starts; its sockets and resolver are the
    #   base's network client, whose `grant` key the template's arguments set. It takes no
    #   shell and no erx_session: the session has no
    #   console and reaches its facets through erx:cap/1.
    # * bleuart, root's shell over Nordic's UART service (docs/design-bluetooth.md, "The
    #   console"): erx_bleuart, which the bleuart template's -eval starts, and the
    #   Bluetooth client, erx_bt_client, whose erx_gatt_serial handles nus. As ntpd's, it
    #   takes no shell and no erx_session: the shell it gives a phone runs in root's
    #   session, on a tty the session's line opens.
    # session and app each take SESSION_BASE, whose erx_session (DOMAIN_ONLY) they only
    # load, as every session template's -eval starts it once the domain holds its facets.
    RELEASE_SCRIPTS = { 'erts' => DOMAIN_BASE,
                        'session' => [*SESSION_BASE, *DOMAIN_IMAGE_ONLY, *DomainStartup::DISPLAY_CLIENT,
                                      'erx_web_line', 'erx_tty_line'].freeze,
                        'storage' => [*DOMAIN_BASE, 'erx_blk', 'erx_fat', 'erx_storage', 'erx_f2fs'].freeze,
                        'network' => [*DOMAIN_BASE, 'erx_net'].freeze,
                        'web' => [*DOMAIN_BASE, 'erx_web'].freeze,
                        'display' => [*DOMAIN_BASE, 'erx_memdraw', 'erx_display', 'erx_fb'].freeze,
                        'client' => [*DOMAIN_BASE, *DomainStartup::DISPLAY_CLIENT, 'erx_ui', 'erx_desk'].freeze,
                        'ssh' => [*DOMAIN_BASE, 'asn1', 'crypto', 'public_key', 'ssh'].freeze,
                        DomainStartup::APP_TEMPLATE.release =>
                          [*SESSION_BASE, 'compiler', 'asn1', 'crypto', 'public_key', 'ssl', 'inets', *DomainStartup::DISPLAY_CLIENT,
                           'erx_ui', 'erx_app', 'erx_bt_client'].freeze,
                        'usb' => [*DOMAIN_BASE, 'erx_blk', 'erx_usb'].freeze,
                        'bt' => [*DOMAIN_BASE, 'crypto', 'erx_bt_client', 'erx_bt'].freeze,
                        'pcie' => [*DOMAIN_BASE, 'erx_pcie'].freeze,
                        'ntpd' => [*DOMAIN_BASE, 'erx_ntpd'].freeze,
                        'bleuart' => [*DOMAIN_BASE, 'erx_bt_client', 'erx_bleuart'].freeze,
                        'wifi' => [*DOMAIN_BASE, 'crypto', 'erx_wifi'].freeze,
                        'media' => [*DOMAIN_BASE, 'erx_fat', 'erx_media'].freeze }.freeze

    # Refuses applications of which no release holds one: an application the runtime
    # builds that neither the system release (system) nor a script of the release
    # scripts table (boots) names would be built and booted nowhere, the sign of a
    # release list forgotten.
    def self.check_released(applications, system:, boots:)
      unreleased = applications - system - boots.values.flatten
      raise Error, "no release holds #{unreleased.join(', ')}: name each in SYSTEM_APPLICATIONS or a RELEASE_SCRIPTS script" unless
        unreleased.empty?
    end
    check_released(APPLICATIONS, system: SYSTEM_APPLICATIONS, boots: RELEASE_SCRIPTS)

    # Where the one domain release lies: domains/erxos/, which sorts after boot/ and
    # before system/, so it is one run of whole entries that does not split the system
    # run (docs/design-fiasco.md, "The production image").
    DOMAINS_PREFIX = 'domains/'
    DOMAIN_PREFIX = "#{DOMAINS_PREFIX}#{NAME}/".freeze

    # One boot script of the domain release: its name, which a domain row's
    # `release @artifact.NAME` names, the applications it boots, and whether it is a test
    # image's, which alone may boot a test-only application (ErlangApps::TEST_ONLY).
    DomainBoot = Data.define(:name, :applications, :test) do
      def initialize(name:, applications:, test: false) = super

      # The applications the script starts, in release order (ReleaseFiles.started?).
      def started = applications.select { |application| ReleaseFiles.started?(application, script: name) }
    end

    # Whether the boot script named script starts an application it holds: every one but
    # those it only loads (LOADED), unless the script starts it all the same
    # (SCRIPT_STARTS). release_entry writes each start type by it and DomainBoot#started
    # reports by it, so what the checked context records a script starts is what the
    # script's release file says.
    def self.started?(application, script:) =
      !LOADED.include?(application) || SCRIPT_STARTS.fetch(script, []).include?(application)
    # Every application a test image's domain boot script may take, in release order.
    TEST_APPLICATIONS = [*APPLICATIONS, *ErlangApps::TEST_ONLY].freeze

    # The boot script named name, of applications, which the runtime builds,
    # DOMAIN_BASE among them, since a release boots through it. A name is a manifest
    # identifier, so a domain row's @artifact.NAME names the script, and it is one path
    # component. Only a test script, test true, which only a test image carries
    # (ProductionImage's test entry point), boots a test-only application.
    def self.domain_boot(name, applications:, test: false)
      raise Error, "a domain boot script's name is an identifier, not #{name.inspect}" unless
        name.is_a?(String) && name.match?(Manifest::Frontend::IDENTIFIER) && !name.include?('/')
      tests = applications & ErlangApps::TEST_ONLY
      raise Error, "only a test image's domain boot script boots a test-only application: #{tests.join(', ')}" unless
        test || tests.empty?
      unknown = applications - TEST_APPLICATIONS
      raise Error, "a domain boot script boots only applications the runtime builds, not #{unknown.join(', ')}" unless unknown.empty?
      missing = DOMAIN_BASE - applications
      raise Error, "a domain boot script boots what every domain's kernel starts: #{missing.join(', ')}" unless missing.empty?

      DomainBoot.new(name: name, applications: (TEST_APPLICATIONS & applications).freeze, test: test)
    end

    # The one domain release: each file of boots' applications once, and a boot script
    # for each of boots, so a domain boots only its own script's applications while the
    # archive stores what the scripts share once. Each of boots is one domain_boot made,
    # and two of one name are refused.
    def self.domain(boots)
      raise Error, 'a domain release has a boot script' if boots.empty?
      raise Error, 'a domain boot script is one ReleaseFiles.domain_boot made' unless
        boots.all? { |boot| boot.is_a?(DomainBoot) && boot == domain_boot(boot.name, applications: boot.applications, test: boot.test) }
      raise Error, 'two domain boot scripts share a name' unless boots.map(&:name).uniq.size == boots.size

      Release.new(name: NAME, prefix: DOMAIN_PREFIX, applications: (TEST_APPLICATIONS & boots.flat_map(&:applications)).freeze,
                  system: false, boots: boots.sort_by(&:name).to_h { |boot| [boot.name, boot.applications] }.freeze)
    end

    # What a domain row's release names in an archive's sorted paths: each boot script
    # of the domain release, domains/erxos/bin/<name>.boot, as artifact <name>, which is
    # the release's whole run of entries (the index of its first entry and its count of
    # files), so every name gives the one slice and a row's name picks only its script.
    # The paths ascend strictly, so the release is one run; a list out of order is
    # refused, and so is a file under domains/ outside the release or a release with no
    # boot script.
    def self.domain_runs(paths)
      raise Error, 'archive paths must ascend strictly' unless paths.each_cons(2).all? { |left, right| left.b < right.b }

      run = paths.each_index.select { |index| paths[index].b.start_with?(DOMAINS_PREFIX) }
      stray = run.map { |index| paths[index] }.find { |path| !path.b.start_with?(DOMAIN_PREFIX) }
      raise Error, "#{stray} is not in the domain release" if stray
      return {}.freeze if run.empty?

      slice = { 'kind' => 'release', 'entry' => run.first, 'files' => run.size }.freeze
      names = run.filter_map { |index| paths[index].b[%r{\A#{DOMAIN_PREFIX}bin/([^/]+)\.boot\z}o, 1] }
      raise Error, 'the domain release has no boot script' if names.empty?

      names.to_h { |name| [name, slice] }.freeze
    end

    # What a manifest's references to the domain release name in an archive of these
    # sorted paths, which carries boots: each script's run (domain_runs) with the
    # applications the script starts (DomainBoot#started), which the manifest check reads
    # of every script a display's grant holder boots (property 18). An archive whose
    # scripts are not boots' own, one more or one fewer, is refused.
    def self.domain_artifacts(paths, boots:)
      runs = domain_runs(paths)
      raise Error, "the archive's domain boot scripts (#{runs.keys.sort.join(', ')}) are not those given " \
                   "(#{boots.map(&:name).sort.join(', ')})" unless runs.keys.sort == boots.map(&:name).sort

      boots.to_h { |boot| [boot.name, runs.fetch(boot.name).merge('started' => boot.started).freeze] }.freeze
    end

    # otp is the built OTP copy; directory is where each boot script, under
    # boot/<name>/, and the receipts go;
    # release is which release they are, the system release unless a domain's is asked;
    # test_roots are the root files a test image adds to the trust store after the
    # tree's (TrustStore.store), none in any other image.
    def initialize(root:, otp:, directory:, runner:, codec:, oracle: Oracle.new(root: root, runner: runner), release: SYSTEM,
                   test_roots: [])
      raise Error, 'a release is a ReleaseFiles::Release' unless release.is_a?(Release)

      @root = root
      @otp = otp
      @directory = directory
      @runner = runner
      @codec = codec
      @oracle = oracle
      @release = release
      @test_roots = test_roots.dup.freeze
    end

    # Each file as an entry for Pack#build, with its receipt written.
    def entries
      FileUtils.mkdir_p(@directory)
      [*application_files, *boot_files].map { |file| file_entry(file) }
    end

    # Where a domain mounts a facet of another domain when the manifest grants it one
    # (erx_ns:mount_facets/1; docs/design-files.md, "A facet's mount"). Each is an empty
    # directory of every release, so where nothing is mounted the path is the release's
    # own empty directory, as FreeBSD shows a mount point with nothing mounted on it.
    # Each is the place of its name in erx_ns:place/1 (erlang/apps/erx/src/erx_ns.erl),
    # and release_files_test compares the two.
    MOUNT_POINTS = %w[data media].freeze

    # Each mount point as an empty directory entry for Pack#build: no artifact, no receipt.
    def directories
      MOUNT_POINTS.map do |name|
        { 'path' => "#{@release.prefix}#{name}", 'kind' => @codec.member('entry_kind', 'directory'),
          'flags' => @release.system ? @codec.member('entry_flags', 'system') : 0 }
      end
    end

    # The files a pack's build inputs must name for these entries: each built file and its
    # receipt, and the sources the receipts name in erXos's own applications among
    # applications, the release's, test-only ones included. OTP's sources are in its
    # imported tree's catalog already. An empty directory entry has no artifact.
    def self.inputs_of(entries, root:, otp:, applications: ErlangApps::APPLICATIONS)
      own = applications.select { |application| ErlangApps.own?(application) }
      built = entries.select { |entry| entry.key?('artifact') }
      [*built.flat_map { |entry| [entry.fetch('artifact'), entry.fetch('receipt')] }, *ErlangApps.sources(root: root, otp: otp, applications: own)]
    end

    # What one application ships, as paths under its directory to the files they copy:
    # its beams and .app from the build at otp, no .appup since an update replaces a whole
    # slot, and its headers (headers). The release and the oracle's hosted tree both lay
    # an application out from here; only the release adds public_key's trust store.
    def self.application_layout(root:, otp:, application:)
      ebin = File.join(otp, 'lib', application, 'ebin')
      built = Dir.glob('*.{beam,app}', base: ebin).sort.map { |name| ["ebin/#{name}", File.join(ebin, name)] }
      [*built, *headers(root: root, application: application).map { |header| ["include/#{File.basename(header)}", header] }]
    end

    # An application's headers: the plain files include/*.hrl at the top of its include/
    # in the tree. Nothing builds them, so each ships as it is and is its own source. A
    # subdirectory does not ship, nor does a generated header, which is in build/gen; a
    # link is refused, so no header ships another file's bytes under its name.
    def self.headers(root:, application:)
      include = File.join(root, source_directory(application), 'include')
      Dir.glob('*.hrl', base: include).sort.map do |name|
        path = File.join(include, name)
        raise Error, "#{path} is not a plain file" unless File.lstat(path).file?

        path
      end
    end

    # Where an application's sources are, relative to the root: OTP's own under otp/lib.
    def self.source_directory(application)
      return ErlangApps.source(application) if ErlangApps.own?(application)

      File.join('otp/lib', application)
    end

    # An application's resource file, the .app.src its .app is made from: the one
    # <application>.app.src beneath its src, which is src/ itself but for an OTP
    # application whose src has subdirectories, as inets' does (src/inets_app).
    def self.app_resource(root:, application:)
      source = File.join(root, source_directory(application), 'src')
      found = Dir.glob("**/#{application}.app.src", base: source)
      raise Error, "#{source_directory(application)}/src holds #{found.size} #{application}.app.src, not one" unless found.size == 1

      File.join(source, found.first)
    end

    # The version an application's .app file in ebin names.
    def self.app_version(ebin, application)
      text = File.read(File.join(ebin, "#{application}.app"))
      text[/\{vsn,\s*"([^"]+)"\}/, 1] or raise Error, "#{application}.app names no version"
    end

    # The ERTS version of the OTP build at otp.
    def self.erts_version(otp)
      File.read(File.join(otp, 'erts/vsn.mk'))[/^VSN\s*=\s*(\S+)/, 1] or raise Error, 'erts/vsn.mk names no version'
    end

    # OTP's own generator: systools:make_script, run by the stock emulator at `erl`,
    # writes start.script and start.boot into `directory` from `release`, a release
    # file's text, and the .app files of the applications it names, found in `paths` and
    # then on the stock emulator's own code path; the result is the boot script's path.
    # `layout: :build` writes each application's code path as $ROOT/lib/<name>/ebin, as
    # OTP's own build tree and bootstrap scripts lay applications out (systools' internal
    # otp_build flag); the default is a release's $ROOT/lib/<name>-<version>/ebin.
    # `dot_erlang: true` keeps the boot's read of .erlang, as stock's start_clean does.
    # systools takes `*` in a path as a wildcard, so a path holding one is refused. The
    # generator itself boots without reading the developer's .erlang.
    def self.make_boot_script(erl:, directory:, release:, paths:, runner:, layout: :release, dot_erlang: false)
      wild = paths.select { |path| path.include?('*') }
      raise Error, "systools would take * in #{wild.join(', ')} as a wildcard" unless wild.empty?

      File.write(File.join(directory, 'start.rel'), release)
      name = File.join(directory, 'start')
      flags = [*{ release: [], build: ['otp_build'] }.fetch(layout), *('no_dot_erlang' unless dot_erlang), 'no_warn_sasl']
      options = ["{path,[#{paths.map { |path| erlang_string(path) }.join(',')}]}", *flags]
      expression = "ok=systools:make_script(#{erlang_string(name)},[#{options.join(',')}]),halt()."
      runner.run([erl, '-boot', 'no_dot_erlang', '-noshell', '-noinput', '-eval', expression],
                 name: 'release-boot-script', deadline: BOOT_DEADLINE, chdir: directory, env: Oracle::CLEAN_ERLANG_ENV)
      "#{name}.boot"
    end

    # A text as an Erlang string literal, its backslashes and quotes escaped.
    def self.erlang_string(text) = "\"#{text.gsub(/[\\"]/) { |character| "\\#{character}" }}\""

    private

    # A header is its own source; a built file names the one it is compiled from.
    # public_key also carries the trust store.
    def application_files
      @release.applications.flat_map do |application|
        directory = "#{@release.prefix}lib/#{application}-#{version(application)}"
        files = self.class.application_layout(root: @root, otp: @otp, application: application).map do |path, artifact|
          sources = path.start_with?('include/') ? [artifact] : sources_of(application, File.basename(path))
          ReleaseFile.new(path: "#{directory}/#{path}", artifact: artifact, sources: sources)
        end
        application == TrustStore::APPLICATION ? [*files, trust_store(prefix: directory)] : files
      end
    end

    # The image's trust store as a file under prefix, public_key's directory in the archive
    # (docs/design-crypto.md, "The trust store"): the tree's roots joined in name order,
    # then a test image's own, written beside the receipts, with each tree root and each
    # test root's source as a source.
    def trust_store(prefix:)
      trust_directory = File.join(@root, TrustStore::DIRECTORY)
      artifact = File.join(@directory, 'trust', File.basename(TrustStore::PATH))
      FileUtils.mkdir_p(File.dirname(artifact))
      File.binwrite(artifact, TrustStore.store(trust_directory, test_roots: @test_roots))
      ReleaseFile.new(path: "#{prefix}/#{TrustStore::PATH}", artifact: artifact,
                      sources: [*TrustStore.roots(trust_directory), *@test_roots.map(&:source)])
    end

    # The source a built file is compiled from: for erXos's applications one of the
    # modules ErlangApps compiles, generated ones included. A file with none named is a
    # failure, so no file reaches the archive without its license.
    def sources_of(application, name)
      base = File.basename(name, '.*')
      return [self.class.app_resource(root: @root, application: application)] if name.end_with?('.app')

      found = ErlangApps.own?(application) ? [erxos_source(application, base)].compact : otp_sources(application, base)
      raise Error, "no source in #{self.class.source_directory(application)} for #{name}" if found.empty?

      found
    end

    def erxos_source(application, base)
      module_path = ErlangApps.modules(root: @root, application: application).find { |path| File.basename(path, '.erl') == base }
      return File.join(@root, module_path) if module_path

      ErlangApps.derived_sources(application, otp: @otp).find { |path| File.basename(path, '.erl') == base }
    end

    # An OTP module's source: its Erlang, or the parser or lexer definition yecc or leex
    # generates it from, or, for a module public_key's asn1 make generates, its ASN.1
    # specification, or a set of them (M.set.asn) with each specification the set names,
    # since the generated module carries each one's license.
    def otp_sources(application, base)
      directory = File.join(@root, self.class.source_directory(application))
      found = %w[erl yrl xrl].map { |extension| File.join(directory, 'src', "#{base}.#{extension}") }
                             .find { |path| File.file?(path) } ||
              Dir.glob(File.join(directory, '**', "#{base}.erl")).min
      return [found] if found

      Asn1Specifications.sources(File.join(directory, 'asn1'), base)
    end

    def version(application) = self.class.app_version(File.join(@otp, 'lib', application, 'ebin'), application)

    def erts_version = self.class.erts_version(@otp)

    # The release's boot scripts, bin/<name>.boot each: a script's release file names
    # its own applications, and the stock host build's systools writes the script from
    # it (ReleaseFiles.make_boot_script), each in a directory of its own. A domain
    # script's release is named after the script, so init:script_id() in a domain names
    # the script it booted; the system release's one script keeps the release's name.
    def boot_files
      @release.boots.map do |name, applications|
        directory = File.join(@directory, 'boot', name)
        FileUtils.mkdir_p(directory)
        boot = self.class.make_boot_script(
          erl: @oracle.erl_path(Runtime::HOST_OTP_FLAVOUR), directory: directory, runner: @runner,
          paths: applications.map { |application| File.join(@otp, 'lib', application, 'ebin') },
          release: "{release,{\"#{@release.system ? @release.name : name}\",\"1\"},{erts,\"#{erts_version}\"}," \
                   "[#{applications.map { |application| release_entry(application, script: name) }.join(',')}]}.\n"
        )
        sources = applications.map { |application| self.class.app_resource(root: @root, application: application) }
        ReleaseFile.new(path: "#{@release.prefix}bin/#{name}.boot", artifact: boot, sources: sources)
      end
    end

    # An application's term in the release file of the boot script named script: its name
    # and version, and the start type load for one the script does not start (started?),
    # DOMAIN_ONLY's and DOMAIN_IMAGE_ONLY's among them but for SCRIPT_STARTS; the others
    # take systools' default, permanent.
    def release_entry(application, script:)
      term = "#{application},\"#{version(application)}\""
      if self.class.started?(application, script: script)
        "{#{term}}"
      else "{#{term},load}"
      end
    end

    def file_entry(file)
      receipt = File.join(@directory, 'receipts', "#{file.path.tr('/', '_')}.json")
      FileUtils.mkdir_p(File.dirname(receipt))
      File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(file.artifact),
                                               'sources' => file.sources.map { |source| reference(source) }))
      { 'path' => file.path, 'kind' => @codec.member('entry_kind', 'file'), 'flags' => @release.system ? @codec.member('entry_flags', 'system') : 0,
        'id' => file.path, 'artifact' => file.artifact, 'receipt' => receipt }
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
