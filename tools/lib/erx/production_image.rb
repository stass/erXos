# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'abi'
require_relative 'boot_file'
require_relative 'boot_partition'
require_relative 'build_facts'
require_relative 'build_inputs'
require_relative 'build_path'
require_relative 'crash_frame'
require_relative 'deterministic_transcript'
require_relative 'dom_planner'
require_relative 'error'
require_relative 'fiasco'
require_relative 'fiasco_provenance'
require_relative 'generated'
require_relative 'files_guest'
require_relative 'hostlink_guest'
require_relative 'reload_guest'
require_relative 'code_watch'
require_relative 'json_input'
require_relative 'manifest'
require_relative 'native_root'
require_relative 'native_jit_runtime'
require_relative 'native_runtime'
require_relative 'output_directory'
require_relative 'pack'
require_relative 'pack_provenance'
require_relative 'pack_tools'
require_relative 'platform'
require_relative 'data_volume'
require_relative 'qemu'
require_relative 'release_files'
require_relative 'release_medium'
require_relative 'runner'

module Erx
  # The image the system boots from: bootstrap as the first stage, and an archive that
  # Pack's one funnel builds and Phase 1's manifest check admits (docs/design-stopgap.md,
  # "The Phase 1 manifest check"). Test images come from BootImage instead, whose
  # structural recipe lives under test/fixtures; nothing here reaches that recipe.
  class ProductionImage
    # The kind of build every image is, which the archive header's development bit
    # records and uname -i names (BuildFacts.configuration).
    BUILD_KIND = 'development'
    # The code that gathers and writes the build-facts file (BuildFacts, SourceRevision,
    # build_facts_file, build_facts_entry and Fiasco#kernel_name), which its receipt names as its sources.
    BUILD_FACTS_SOURCES = %w[tools/lib/erx/build_facts.rb tools/lib/erx/source_revision.rb tools/lib/erx/production_image.rb
                             tools/lib/erx/fiasco.rb].freeze
    ROOT_ENTRY_PATH = 'system/root'
    NOTICES_PATH = 'system/NOTICES'
    # No more RAM than root_memory, of which Fiasco and the archive take their part first,
    # so the pool falls short and the root must refuse the boot. The development machine's
    # root, 64 MiB into RAM, ends inside it, and QEMU's device tree, at half of RAM below
    # 256 MiB, lies below the root there, so the root, not bootstrap, refuses.
    TOO_LITTLE_MEMORY_MIB = 96
    # What a machine keeps for the root's image past its place: the image is about 5 MiB.
    ROOT_ROOM_MIB = 8
    LICENSE = 'LICENSE'
    # The trees imported into the source tree that the root builds from: BLAKE3 for its
    # reader of the archive and the entropy generator's mixing, ChaCha20 for that
    # generator's stream, OTP for the release's beams, and libfdt for its device-tree reader.
    IMPORTS = { 'kernel/crypto/blake3' => 'permanent', 'kernel/crypto/chacha20' => 'permanent', 'otp' => 'permanent',
                'fiasco/libfdt' => 'permanent' }.freeze

    # The emulator's archive, which holds littlefs's objects beside ERTS's own
    # (otp/erts/emulator/Makefile.in's OS_OBJS), so its attribution carries
    # littlefs's BSD-3-Clause notice as well as OTP's.
    EMULATOR_ARCHIVE = 'libbeam.a'

    # One of the archives that the root links, attributed whole under the license
    # stated here, with notices the tree paths of the documents that license names.
    # TODO.md holds the gap: the boot cores hold BLAKE3 as well.
    Archive = Data.define(:path, :label, :license, :status, :notices)

    # flags are the archive header's, as the kernel's banner line reports them; test_code
    # is their ERX_PACK_TEST_CODE bit, set only in an image build_test_image made. release
    # is the system release's entries, which the release medium's EROFS image, erofs, holds;
    # the archive's manifest records that image's extent.
    Built = Data.define(:single, :archive, :first_stage, :index_hash, :build_id, :flags, :test_code, :report, :release, :erofs)

    # What a test image adds to the system release (OracleQemu): entries for Pack#build,
    # each with its receipt, the files those receipts name, and the imported trees their
    # sources come from, each with its status. A production image adds nothing.
    Added = Data.define(:entries, :inputs, :imports)
    NOTHING_ADDED = Added.new(entries: [].freeze, inputs: [].freeze, imports: {}.freeze)
    private_constant :NOTHING_ADDED

    # An image carries one domain release (ReleaseFiles.domain) with a boot script for
    # each name its manifest's domain rows and session templates give as their release
    # (domain_boots), and with it the one runtime image every domain runs. The build's
    # boot table defines a script's applications under its name (docs/design-stopgap.md,
    # "The production image"); the manifest only names the script, so two rows naming
    # one cannot disagree on what it boots. The session script, which a principal's
    # session domain boots, adds the network client (ReleaseFiles::NETWORK_ONLY), whose
    # `grant` key the session template's arguments set, the command shell, the session's
    # line to the web domain (ReleaseFiles::SESSION_ONLY) and erx_session
    # (docs/design-domains.md, "Principals, sessions and quotas"); the storage script adds
    # the block driver and littlefs's volume, which the system release does not ship
    # (ReleaseFiles::STORAGE_ONLY; docs/design-stopgap.md, "littlefs in the storage domain"); the
    # network script adds the network stack, which it starts permanent, so the stack's end
    # ends the network domain (docs/design-network-stack.md, "The process tree"); the
    # web script adds the web front end (ReleaseFiles::WEB_ONLY; docs/design-web.md); a name
    # the table does not hold boots DOMAIN_APPLICATIONS, the applications every domain
    # boots through. The development manifest's session template names the session
    # script, and its storage, network and web rows the scripts of those names;
    # medium_boot's manifest configures a domain (MediumBoot.manifest), and a test image
    # may carry more scripts (build_test_image's domains).
    DOMAIN_APPLICATIONS = ReleaseFiles::DOMAIN_BASE
    DOMAIN_BOOTS = { 'session' => [*DOMAIN_APPLICATIONS, 'erx_net_client', 'erx_shell', *ReleaseFiles::SESSION_ONLY,
                                   'erx_session'].freeze,
                     'storage' => [*DOMAIN_APPLICATIONS, *ReleaseFiles::STORAGE_ONLY].freeze,
                     'network' => [*DOMAIN_APPLICATIONS, 'erx_net'].freeze,
                     'web' => [*DOMAIN_APPLICATIONS, *ReleaseFiles::WEB_ONLY].freeze }.freeze

    # Refuses a test script (ReleaseFiles::DomainBoot#test) among domains unless the image
    # is a test image, whose archive flags mark its test code, so no image without the
    # mark boots a test-only application.
    def self.check_test_scripts(domains, test_code:)
      tests = domains.select(&:test).map(&:name)
      raise Error, "only a test image carries a test domain boot script: #{tests.join(', ')}" unless test_code || tests.empty?
    end

    # The domain boot script named name, with the applications the boot table gives it.
    def self.domain_boot(name) = ReleaseFiles.domain_boot(name, applications: DOMAIN_BOOTS.fetch(name, DOMAIN_APPLICATIONS))
    # A domain's runtime image in the archive: the interpreter's, under the flavour
    # erx_domain's spec names it by (docs/design-domains.md, "Erlang interface"), and the
    # artifact name a domain row's runtime takes. It sorts after domains/ and before
    # system/, and carries no system mark, since the root task does not run it.
    DOMAIN_RUNTIME_PATH = 'runtimes/emu'
    DOMAIN_RUNTIME_ARTIFACT = 'emu'
    # The BeamAsm image beside it, which ordinary domains run by default: the one entry
    # whose manifest carries ERX_IMAGE_JIT (docs/design-runtime.md, "The build").
    JIT_RUNTIME_PATH = 'runtimes/jit'
    JIT_RUNTIME_ARTIFACT = 'jit'
    # The C++ runtime archives' notices, in the fetched llvm-project tree.
    LIBCXX_NOTICES = { 'libc++.a' => 'libcxx/LICENSE.TXT', 'libc++abi.a' => 'libcxxabi/LICENSE.TXT' }.freeze

    # The machine an image boots on: its board's platform record (Platform), its RAM, the part of it Fiasco keeps
    # (fiasco_reserve, which grows with RAM, since Fiasco sizes its kernel memory as
    # 6% of it), system_growth_mib, which is added to both root_memory and
    # system_baseline of the development manifest, and tmp_growth_mib, which is added
    # to /tmp's cap and is part of the system growth, since /tmp lives in the baseline,
    # and root_mib, the root task's place in MiB from the start of RAM (root_address),
    # counted from the record's ram_first, which the root's link takes
    # (liberx/backend/fiasco/root.ld). The root is a fixed
    # image, so each machine names its place: low on a small machine, whose RAM must
    # hold the root, and higher where a test image's archive, which lies below the
    # root, is larger.
    # What the system growth leaves of the added RAM widens the room bootstrap keeps
    # for the archive. The production image boots on the development machine
    # (Machine.development), the platform record's own; a test image whose suites need more memory or carry a
    # larger archive (OracleQemu) names a larger one, and Pack's manifest check proves
    # the grown manifest against the platform record of that machine as it proves the
    # development one.
    Machine = Data.define(:platform, :memory_mib, :fiasco_reserve_mib, :system_growth_mib, :tmp_growth_mib, :root_mib) do
      # The record's own machine: its RAM and fiasco_reserve, the root at NativeRoot's
      # development place.
      def self.development(platform)
        new(platform: platform, memory_mib: platform.memory_mib, fiasco_reserve_mib: platform.fiasco_reserve_mib,
            system_growth_mib: 0, tmp_growth_mib: 0, root_mib: NativeRoot::DEVELOPMENT_ROOT_MIB)
      end

      def initialize(platform:, **numbers)
        raise Error, 'a machine is on a Platform' unless platform.is_a?(Platform)

        super
      end

      # The root's place, with room for the root's image (about 5 MiB) before RAM ends.
      def root_address
        raise Error, "the root's place, #{root_mib} MiB into RAM, leaves no room for it in #{memory_mib} MiB" if
          root_mib.negative? || root_mib + ROOT_ROOM_MIB > memory_mib

        platform.ram_first + (root_mib << 20)
      end

      # The platform record as Pack's manifest check proves this machine's manifest against it.
      def record = platform.record.merge('ram_bytes' => memory_mib << 20, 'fiasco_reserve' => fiasco_reserve_mib << 20)

      # The board's development manifest, as this machine boots it (manifest).
      def test_manifest(root) = manifest(platform.manifest_source(root))

      # The development manifest's text for a test image on this machine: with no session
      # template (ProductionImage.without_sessions), so the console's login at boot starts
      # no session and the UART stays with the system shell, and with root_memory and
      # system_baseline each grown by system_growth_mib and the system domain's /tmp cap,
      # its runtime limits' tmp, by tmp_growth_mib; any other line is unchanged.
      def manifest(source)
        raise Error, "/tmp's growth is more than the system's" if tmp_growth_mib > system_growth_mib

        { /^(  root_memory )([0-9]+)$/ => system_growth_mib, /^(  system_baseline )([0-9]+)$/ => system_growth_mib,
          /^(runtime_limits system\n(?:  .*\n)*?  tmp )([0-9]+)$/ => tmp_growth_mib }
          .reduce(ProductionImage.without_sessions(source)) do |text, (pattern, growth_mib)|
            raise Error, "the manifest does not have exactly one line #{pattern.source}" unless text.scan(pattern).size == 1

            text.sub(pattern) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2), 10) + (growth_mib << 20)}" }
          end
      end
    end

    # source with no session template: each `session` record, to the next record, and
    # each facet granted to a session template, which names a template no longer there.
    # The production image keeps its template, so the console logs root in at boot and
    # the UART's first prompt is root's session; a harness whose cells type at the system
    # shell, and every test image (Machine#manifest), boots without one.
    SESSION_RECORD = /^session [a-z0-9_]+\n(?:  .*\n)*/
    def self.without_sessions(source)
      source.gsub(SESSION_RECORD, '')
            .gsub(/^facet [a-z0-9_]+\n(?:  .*\n)*/) { |record| record.match?(/^  grantee @session\./) ? '' : record }
    end

    # source's session templates, each record whole and in order: what without_sessions
    # takes out, for a test image that boots with them (SystemDomain::Regrant).
    def self.sessions(source) = source.scan(SESSION_RECORD).join

    # The development manifest without its session template, for the harnesses that type
    # at the system shell.
    def self.sessionless_manifest(root, platform:) = without_sessions(platform.manifest_source(root))

    def initialize(root:, runner:, compiler:, linker:, machine:, fiasco: Fiasco.new(root: root, runner: runner, compiler: compiler),
                   runtime: NativeRuntime.new(root: root, runner: runner, compiler: compiler, linker: linker, fiasco: fiasco,
                                              platform: platform_of(machine)),
                   jit_runtime: NativeJitRuntime.new(root: root, runner: runner, compiler: compiler, linker: linker,
                                                     fiasco: fiasco, platform: platform_of(machine)))
      platform_of(machine)
      @root = File.realpath(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @machine = machine
      @fiasco = fiasco
      @runtime = runtime
      @jit_runtime = jit_runtime
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
    end

    # Beside an image, the digest of the sources it was built from: what a test compares
    # to know the image is of the tree it checks, whatever else rebuilt the runtime since.
    def self.sources_path(archive) = "#{archive}.sources"

    # Removes the image an earlier build left at path under root, so the next
    # build starts clean, and returns the directory. The check comes first and
    # refuses a path that is, or passes through, a link, so the removal never
    # leaves root.
    def self.clear_directory(root:, path:)
      directory = OutputDirectory.check(root: root, path: path)
      raise Error, 'an image directory must lie below its root' if directory == File.realpath(root)

      FileUtils.remove_entry(directory) if File.exist?(directory)
      directory
    end

    # Packs the image from Fiasco's last build into a directory that must be clean, so a
    # stale file cannot stand in for this build's. The image carries the system release
    # and nothing else.
    def build(directory:, manifest_source: @machine.platform.manifest_source(@root))
      assemble(directory: directory, manifest_source: manifest_source, added: NOTHING_ADDED, test_code: false,
               machine: @machine, domains: domain_boots(manifest_source))
    end

    # Where `tools/erx pack` leaves platform's production image and its medium, replaced
    # whole on every pack.
    def self.packed_directory(platform) = "build/production-image/#{platform.name}"

    # `tools/erx pack`'s one build: Fiasco for platform (Fiasco#build_for), then the
    # production image of platform's development machine, with its medium when medium
    # is set, into packed_directory, cleared first. Returns build's or build_medium's
    # result. The raspi4b suite boots what this leaves.
    def self.pack_platform(root:, runner:, compiler:, linker:, platform:, medium:, jobs: 4)
      fiasco = Fiasco.new(root: root, runner: runner, compiler: compiler)
      fiasco.build_for(platform, jobs: jobs)
      directory = clear_directory(root: root, path: File.join(root, packed_directory(platform)))
      image = new(root: root, runner: runner, compiler: compiler, linker: linker, machine: Machine.development(platform),
                  fiasco: fiasco)
      medium ? image.build_medium(directory: directory) : image.build(directory: directory)
    end

    # The image and the medium that holds it, both in directory, which must be clean: by
    # default the production image. A board the firmware boots from a boot partition
    # (BootPartition.boot_partition_medium?) gets that partition's files and the card, the ABI's medium for the board (PiMedium); any other
    # gets the release medium for QEMU (ReleaseMedium). A boot that creates a domain
    # (MediumBoot) names a larger machine and a manifest with room for it, whose domain
    # row names the release and runtime image the image then carries.
    def build_medium(directory:, machine: @machine, manifest_source: machine.platform.manifest_source(@root))
      on_own_board(machine)
      built = assemble(directory: directory, manifest_source: manifest_source, added: NOTHING_ADDED, test_code: false,
                       machine: machine, domains: domain_boots(manifest_source))
      if BootPartition.boot_partition_medium?(machine.platform)
        return [built, BootPartition.lay_out(root: @root, runner: @runner, platform: machine.platform, build_kind: BUILD_KIND,
                                             bootable: built.single, erofs: built.erofs,
                                             directory: built_directory(built), compiler: @compiler, linker: @linker)]
      end

      [built, release_medium(built)]
    end

    # The release medium for QEMU (ReleaseMedium) of built, an image this object packed, in
    # the image's directory: the image's slot and a new littlefs data volume, so the
    # storage domain serves /data. Returns a ReleaseMedium::Written: the medium's
    # path, and the slot plan, data_sectors and volume a fresh copy is made from.
    def release_medium(built)
      directory = built_directory(built)
      data_sectors = MediumImage.constant('data_sectors_min')
      volume = DataVolume.format(root: @root, runner: @runner, compiler: @compiler, directory: directory, data_sectors: data_sectors)
      ReleaseMedium.write(built: built, directory: directory, volume: volume, data_sectors: data_sectors)
    end

    # The production image with test code added to its system release, marked in its
    # archive's flags (ERX_PACK_TEST_CODE) so the kernel's banner says so and the kernel
    # refuses it in any build but a development one. Only the QEMU harnesses that boot
    # test code, OracleQemu, BlockDevice, SystemDomain, Programs and Apps, call it, which the source check holds
    # (Checks::TEST_IMAGE_BUILDERS). domains are the domain boot scripts it carries
    # (ReleaseFiles.domain_boot) in the one domain release, with the domain runtime image,
    # each in place of the manifest's script of its name; one of them may be a test
    # script, booting a test-only application (ErlangApps::TEST_ONLY), which is test code
    # too. manifest_source is machine's manifest unless a harness names its own.
    def build_test_image(directory:, added:, machine: @machine, domains: [], manifest_source: machine.test_manifest(@root))
      on_own_board(machine)
      raise Error, 'a test image adds test code' unless
        added.is_a?(Added) && (!added.entries.empty? || domains.any?(&:test))

      source = manifest_source
      carried = (domains + domain_boots(source)).uniq(&:name)
      assemble(directory: directory, manifest_source: source, added: added, test_code: true, machine: machine,
               domains: carried)
    end

    # Both entry points' one build: the system release, the domain releases with their
    # runtime image, any additions, and the mark that says whether there are some.
    def assemble(directory:, manifest_source:, added:, test_code:, machine:, domains:)
      self.class.check_test_scripts(domains, test_code: test_code)
      directory = OutputDirectory.prepare(root: @root, path: directory)
      raise Error, 'a production image builds into a clean directory' unless Dir.empty?(directory)

      sources = Runtime.source_digest(root: @root)
      erts = @runtime.build
      archives = [*erts.otp_archives, erts.libc, @fiasco.user_library('libgcc.a')]
      root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: machine.platform,
                                 fiasco: @fiasco)
                            .build_system_receipted(directory: File.join(directory, 'root'), archives: archives,
                                                    place: machine.root_address)
      kernel = assembled_receipt(@fiasco.kernel_path, name: 'kernel', directory: directory)
      sigma0 = assembled_receipt(@fiasco.sigma0_path, name: 'sigma0', directory: directory)
      archive = File.join(directory, 'image.erxpack')
      File.write(self.class.sources_path(archive), sources)
      facts = build_facts_file(directory: directory, platform: machine.platform)
      system_release = ReleaseFiles.new(root: @root, otp: erts.otp, directory: File.join(directory, 'release'), runner: @runner, codec: @codec)
      release = [*system_release.entries, build_facts_entry(facts, release: ReleaseFiles::SYSTEM)]
      erofs, images = ReleaseMedium.image(entries: release, directory: directory, runner: @runner)
      # Only domains run the BeamAsm image, so an image without them does not build it.
      jit = domains.empty? ? nil : @jit_runtime.build(interpreter: erts)
      domain = domain_parts(domains, erts: erts, jit: jit, archives: archives, facts: facts, directory: directory)
      report = pack(entries: [*entries(root_task, kernel, sigma0), *release, *system_release.directories, *domain.entries, *added.entries],
                    root_task: root_task,
                    images: images, manifest_source: manifest_source, erts: erts, jit: jit, output: archive,
                    imports: IMPORTS.merge(added.imports),
                    inputs: [kernel, sigma0, *ReleaseFiles.inputs_of(release, root: @root), *build_facts_sources, *domain.inputs,
                             *added.inputs].uniq,
                    test_code: test_code, machine: machine)
      single = File.join(directory, 'image.boot')
      BootFile.write(codec: @codec, first_stage: @fiasco.first_stage_path(machine.platform), archive: archive, output: single, output_root: @root)
      # image.boot holds every file of the image, the release's included, as packed, so
      # one look at it finds a file that names the tree (BuildPath). A test image, which
      # never leaves the build host, is not looked at.
      host = test_code ? nil : BuildPath.find_in(File.binread(single), root: @root)
      raise Error, "production image: #{File.basename(single)} holds the build's path #{host}" if host

      header = @codec.decode_layout('erx_pack_header', File.binread(archive, @codec.layout_size('erx_pack_header')))
      flags = header.fetch('flags')
      marked = flags.anybits?(@codec.member('pack_flags', 'test_code'))
      raise Error, 'the archive header disagrees with the test-code mark asked for' unless marked == test_code
      raise Error, "the archive header disagrees with the build kind #{BUILD_KIND} the build facts name" unless
        flags.anybits?(@codec.member('pack_flags', 'development')) == (BUILD_KIND == 'development')

      Built.new(single: single, archive: archive, first_stage: @fiasco.first_stage_path(machine.platform),
                index_hash: header.fetch('index_hash').unpack1('H*'), build_id: header.fetch('build_id').unpack1('H*'),
                flags: flags, test_code: marked, report: report, release: release, erofs: erofs)
    end
    private :assemble

    # build/gen's stamp, read under its lock after the tree is brought up to date.
    def generated_stamp
      stamp = nil
      Generated.ensure(root: @root) { |tree| stamp = File.binread(File.join(tree.output, Generated::STAMP)) }
      stamp
    end
    private :generated_stamp

    # The same inputs give byte-identical images: two whole builds of the runtime, each
    # from a clean runtime directory and packed into a clean directory of its own name
    # with its medium, compared part by part by SHA-256, read as a stream. A board whose
    # medium is a boot partition (BootPartition) builds BL31 afresh for each image too, and
    # its board tree is built for each; the card's image holds every file of the partition,
    # so its digest covers them. A path under those directories that reached an output
    # shows; OTP and musl build at one path
    # both times, so a path of theirs does not. Fiasco's own assembly has its own test
    # (test/integration/fiasco_reproducible_test.rb); both builds here pack its one result.
    # Both builds read build/gen, which the check never replaces while its inputs are
    # unchanged, so it moves no tree from under another build reading it. That the tree
    # is a function of its inputs shows instead in a tree of the check's own, generated
    # into gen/ beside the images and compared file by file with build/gen, whose
    # differences count as differing parts. build/gen's stamp must be the same after
    # both builds as at that comparison, so the builds read the tree it compared.
    def check_reproducible(directory:)
      directory = OutputDirectory.prepare(root: @root, path: directory)
      raise Error, 'a reproducibility check needs a clean directory' unless Dir.empty?(directory)

      generated = Generated.regeneration_differences(root: @root, scratch: File.join(directory, 'gen'))
      compared = generated_stamp
      (first, first_medium), (second, second_medium) = %w[first second].map do |name|
        @runtime.clean
        Bl31.clean(root: @root) if BootPartition.boot_partition_medium?(@machine.platform)
        build_medium(directory: File.join(directory, name))
      end
      raise Error, 'build/gen was regenerated during the reproducibility check; run it again' unless generated_stamp == compared

      first_digests = digests(first, first_medium)
      second_digests = digests(second, second_medium)
      differing = generated.map { |relative| File.join(Generated::OUTPUT, relative) } +
                  first_digests.keys.reject { |part| first_digests.fetch(part) == second_digests.fetch(part) }
      report = { 'kind' => 'production_image_reproducibility', 'byte_identical' => differing.empty?,
                 'differing' => differing, 'first' => first_digests, 'second' => second_digests,
                 'manifest' => first.report.fetch('manifest') }
      path = File.join(directory, 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      unless differing.empty?
        raise Error, "the production image differs across clean builds: #{differing.join(', ')}; #{path}"
      end

      report.merge('report' => path).freeze
    end

    # The problems of a platform record against a device tree as dtc prints it: a RAM base
    # (ram_first) other than the tree's first memory node's, and each device's problems
    # (device_problems). It reads QEMU virt's tree, whose nodes all sit at the top level
    # with two address cells and whose clocks are fixed-clock nodes; the Raspberry Pi's
    # tree, whose UARTs sit under /soc and whose clocks the firmware sets, is not of
    # that shape, and its records are not checked this way.
    def self.device_path_problems(platform, dts)
      nodes = dts.scan(/^\t([^\s{}]+) \{\n(.*?)^\t\};/m).to_h do |name, body|
        ["/#{name}", { compatible: body[/^\t\tcompatible = (.*?);/, 1].to_s.scan(/"([^"]+)"/).flatten,
                       window: node_window(body), reg: cells(body, 'reg'), phandle: cells(body, 'phandle').first,
                       clocks: cells(body, 'clocks'), frequency: cells(body, 'clock-frequency') }]
      end
      ram_problems(platform, nodes) + device_problems(platform, nodes)
    end

    # Each device-tree device's problem: a path the tree lacks, a node whose compatible
    # list does not name what the record says, a window or line other than the node's, or
    # a PL011's clock other than the tree's (pl011_clock_problem).
    def self.device_problems(platform, nodes)
      devices = platform.fetch('units').flat_map { |unit| unit.fetch('devices') }.select { |device| device.fetch('selector') == 'dt' }
      devices.filter_map do |device|
        path = device.fetch('path')
        node = nodes[path]
        recorded = %i[base size line].to_h { |field| [field, device[field.to_s]] }
        if node.nil?
          "#{path}: not in the device tree"
        elsif !node.fetch(:compatible).include?(device.fetch('compatible'))
          "#{path}: compatible #{node.fetch(:compatible).inspect} does not name #{device.fetch('compatible')}"
        elsif recorded != node.fetch(:window)
          "#{path}: base, size or line #{recorded} differ from the tree's #{node.fetch(:window) || 'unreadable reg or interrupts'}"
        elsif device.fetch('compatible') == Manifest::SystemDomainCheck::PL011_COMPATIBLE
          pl011_clock_problem(path, device, node, nodes)
        end
      end
    end
    private_class_method :device_problems

    # A PL011's clock is its node's first clocks entry, uartclk by the PL011 binding: the
    # phandle of a fixed-clock node, whose one clock-frequency cell is the clock in hertz.
    # A record whose clock is another, or absent, or a tree whose clock is not such a node,
    # is a problem, since erx_pl011 divides the baud rate from that clock.
    def self.pl011_clock_problem(path, device, node, nodes)
      phandle = node.fetch(:clocks).first
      source = phandle && nodes.each_value.find { |candidate| candidate.fetch(:phandle) == phandle }
      frequency = source.fetch(:frequency) if source&.fetch(:compatible)&.include?('fixed-clock')
      tree = frequency&.size == 1 ? frequency.first : nil
      return nil if tree && device['clock'] == tree

      "#{path}: clock #{device['clock'].inspect} differs from the tree's #{tree || 'unreadable fixed-clock'}"
    end
    private_class_method :pl011_clock_problem

    # The tree's RAM base is its first memory node's first reg address; a record whose
    # ram_first is another, or a tree with no readable memory node, is a problem.
    def self.ram_problems(platform, nodes)
      first = nodes.filter_map { |path, node| node.fetch(:reg) if path.start_with?('/memory@') }.first
      return ['the device tree has no memory node with a readable reg'] unless first && first.size >= 2

      base = (first.fetch(0) << 32) | first.fetch(1)
      ram_first = platform['ram_first']
      ram_first == base ? [] : [format('ram_first %<record>s differs from the tree\'s RAM base 0x%<base>x', record: ram_first.inspect, base: base)]
    end
    private_class_method :ram_problems

    # A decompiled tree whose console node is renamed, with /chosen/stdout-path naming it
    # through the alias alias_name and with the UART's options after a colon: the same
    # PL011 at the same address, which bootstrap and the kernel still find by stdout-path,
    # under a path the manifest's console is not. dtc merges the appended aliases block
    # into the tree's own. Raises when the tree has no such node or no stdout-path.
    def self.seed_stdout_path(dts, node:, renamed:, alias_name:)
      moved = dts.sub(/^\t#{Regexp.escape(node.delete_prefix('/'))} \{$/) { "\t#{renamed.delete_prefix('/')} {" }
      raise Error, "the device tree has no node #{node} to rename" if moved == dts

      aimed = moved.gsub("\"#{node}\"") { "\"#{renamed}\"" }
                   .sub(/^(\t+)stdout-path = "[^"]*";$/) { "#{Regexp.last_match(1)}stdout-path = \"#{alias_name}:115200n8\";" }
      raise Error, 'the device tree has no /chosen/stdout-path to seed' unless aimed.include?("stdout-path = \"#{alias_name}:")

      "#{aimed}\n/ {\n\taliases {\n\t\t#{alias_name} = \"#{renamed}\";\n\t};\n};\n"
    end

    # A decompiled tree with the dma-coherent mark taken off node, a child of the root,
    # and off the root: the device behind node then reads as not coherent, while QEMU's
    # DMA stays coherent (docs/design-device-tree.md, "The live tree on QEMU"). The
    # root's mark must go too, since a mark above a node that does not carry it itself
    # withholds the node's DMA facts (status coherence); every other device keeps its own
    # mark, which the root's only repeated. The root's property line is one tab deep, the
    # node's two; the node's children's lines are deeper. Raises when the tree has no
    # such node or the node has no mark.
    def self.seed_noncoherent(dts, node:)
      opening = /^\t#{Regexp.escape(node.delete_prefix('/'))} \{\n/
      seeded = dts.sub(/(#{opening}(?:\t\t.*\n)*?)\t\tdma-coherent;\n/) { Regexp.last_match(1) }
      raise Error, "the device tree has no node #{node} marked dma-coherent" if seeded == dts

      seeded.sub(/^\tdma-coherent;\n/, '')
    end

    # QEMU's own tree for the machine argv starts, written by its dumpdtb option, decompiled,
    # passed through the block, which returns the seeded listing, and compiled to path;
    # returns path. -dtb hands a boot this tree in place of the one QEMU would write, so
    # argv must be the boot's own machine: its platform, accelerator, CPUs, memory and
    # command line.
    def self.seeded_tree(runner:, argv:, path:)
      raise Error, "a seeded tree's path ends in .dtb, not #{path}" unless path.end_with?('.dtb')

      FileUtils.mkdir_p(File.dirname(path))
      stock = path.sub(/\.dtb\z/, '-stock.dtb')
      source = path.sub(/\.dtb\z/, '.dts')
      machine = argv.index('-machine') + 1
      runner.run([*argv[0...machine], "#{argv[machine]},dumpdtb=#{stock}", *argv[(machine + 1)..]], name: 'qemu-dumpdtb-seed', deadline: 30)
      listing = File.read(runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', stock], name: 'dtc-seed', deadline: 30).fetch('log'))
      File.write(source, yield(listing))
      runner.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', path, source], name: 'dtc-seeded', deadline: 30)
      path
    end

    # The numbers of a property such as `reg = <0x00 0x9000000 0x00 0x1000>;`.
    def self.cells(body, property) = body[/^\t\t#{property} = <(.*?)>;/, 1].to_s.split.map { |cell| Integer(cell) }
    private_class_method :cells

    # How virt's interrupt controller numbers a line by the type in an interrupt's first cell:
    # shared lines from 32, lines private to a CPU from 16.
    INTERRUPT_FIRST = { 0 => 32, 1 => 16 }.freeze

    # A node's window and line: virt's tree gives each reg entry two address and two size
    # cells, and each interrupt three cells, its type, its number within the type and its
    # flags. nil when the node has no whole reg entry or interrupt of a known type.
    def self.node_window(body)
      reg = cells(body, 'reg')
      type, number = cells(body, 'interrupts')
      return nil unless reg.size >= 4 && INTERRUPT_FIRST.key?(type) && number

      high_base, low_base, high_size, low_size = reg
      { base: (high_base << 32) | low_base, size: (high_size << 32) | low_size, line: INTERRUPT_FIRST.fetch(type) + number }
    end
    private_class_method :node_window

    # Boots the production image under each accelerator and CPU count, after checking
    # the platform record's device paths against QEMU's own device tree. Any disagreement raises.
    class Run
      # What the harness gives each accelerator's kernel command line (docs/design-stopgap.md,
      # "The watchdog"). HVF runs the defaults.
      TCG_WATCHDOG = '1,30,600'
      COMMAND_LINES = { 'tcg' => "erx.watchdog=#{TCG_WATCHDOG}" }.freeze
      # The smoke's cells, both under TCG, the one accelerator that runs deterministic mode.
      SMOKE_CELLS = %w[tcg-1cpu tcg-deterministic].freeze
      # One more word on the deterministic boot's line, which the page must carry too.
      DETERMINISTIC_LINE = 'erx.det=1 erx.arg=-deterministic'
      # The watchdog's numbers for the proof boot under each accelerator of the whole matrix,
      # which TCG never runs: a boot deadline it beats, and a pet deadline.
      PET_PROOF = { 'hvf' => { period: 1, pet: 5, boot: 60 } }.freeze
      # How far past the boot deadline the proof boot stays up, and how long past the pet
      # deadline and the period the stopped pet's crash record may take to appear.
      PET_MARGIN_SECONDS = 5
      # The crash record may come this much before the pet deadline D: the last pet is up to a
      # pet interval older than the suspension, and the harness reads the serial log on a poll.
      PET_EARLY_SECONDS = 2
      # The narrow image's CPUs, 0 and 1: the system share's cpuset, and the bound of every other.
      NARROW_CPUSET = 3
      # erx_console's first line, which only a release that started `kernel` writes.
      SLOGAN = { name: 'release-slogan', pattern: %r{\AErlang/OTP 29 }n, seconds: 240 }.freeze
      # The banner of the command shell erx_console starts after the slogan, which ends the
      # boot; its prompt, `% `, ends no line. erl typed there starts the Erlang shell.
      COMMAND_SHELL_BANNER = 'rc: the command shell; erl starts the Erlang shell'
      RELEASE_SHELL = { name: 'release-shell', pattern: /\A#{Regexp.escape(COMMAND_SHELL_BANNER)}\r*\n\z/n, seconds: 60 }.freeze
      # What the person types at the command shell for the Erlang shell, whose banner starts
      # with Eshell V and whose prompt, `1> `, ends no line.
      ERL_LINE = "erl\r"
      # Ctrl-G opens erx_console's menu, whose first line is its title; Esc, typed alone,
      # leaves it. The menu's last line, "Esc returns. ", has no newline of its own; the
      # console ends it with the close it writes whenever the line changes hands: ESC \ and
      # ESC [0m, which end a string left open and reset the style, then CR-LF. MENU_LEFT
      # matches the close alone. A log line is written whole between whatever else is
      # written (docs/design-live.md, "Log lines and program output"), so one written while
      # the menu is up lands between "Esc returns. " and the close, which then starts a line;
      # a log line cannot hold the close, since the line escape turns its ESC into text. The
      # checkpoint is armed after the menu's title, so the close it sees is the one Esc causes.
      CTRL_G = "\a"
      ESC = "\e"
      CTRL_G_MENU = /\Aerx_console: Ctrl-G menu\r*\n\z/n
      MENU_LEFT = /\e\\\e\[0m\r*\n\z/n
      ERLANG_SHELL = { name: 'erlang-shell', pattern: /\AEshell V/n, seconds: 60 }.freeze
      # kernel_sup's children in the system release, a node over the erx carrier (net_sup
      # holds net_kernel and the connection agent), in which_children's order: the last
      # started first (docs/design-runtime.md, Configuration).
      KERNEL_CHILDREN = %w[kernel_safe_sup kernel_refc kernel_config logger_sup user erl_signal_server
                           global_group net_sup global_name_server rex inet_db erx_watchdog on_load
                           file_server_2 standard_error code_server].freeze
      # From the banner to -eval's first output, which loads the evaluator: long under TCG.
      EVAL_SECONDS = 120
      # An expression for init's -eval: one word, since the kernel command line splits on spaces.
      CHILDREN_EXPRESSION = 'erlang:display([element(1,C)||C<-supervisor:which_children(kernel_sup)])'
      # The suspender must outlive the suspension, which ends when it does.
      STOP_PET = 'erlang:suspend_process(whereis(erx_watchdog)),erlang:display(pet_stopped),timer:sleep(infinity).'

      # The word that starts the group's report (park_report.c).
      GROUP_REPORT_WORD = 'erx.group_report=1'
      # A scheduler busy for half a second, five of the report's looks, whatever the machine's speed.
      BUSY_EXPRESSION = 'Busy=fun Busy(T)->case erlang:monotonic_time(millisecond)>T of true->busy_done;' \
                        "false->Busy(T) end end,Busy(erlang:monotonic_time(millisecond)+500).\r"
      # An erx. word of no known kind, which refuses the boot.
      UNKNOWN_WORD_LINE = 'erx.nosuchword=1'
      # The program's name, the twelve words of the flags erx_boot_argv_plan derives from the
      # page's limits and grant (-P, -Q, -t, -S, -SDcpu and -SDio with their values) and the node
      # flag with its name, around the page's words, and the seven words of -erx console_uart BASE
      # SIZE LINE MARK CLOCK, the four of -erx boot VALUE SLOT and the three of -erx build ID, which the
      # root adds to the manifest's. The allocator flags erx_boot_argv_plan ends its flags with are
      # counted from their one copy (allocator_words).
      ARGUMENTS_FIXED = 29
      # The file whose ALLOCATOR_WORDS string holds the allocator flags of every runtime.
      BOOT_INFO = 'liberx/backend/core/boot_info.c'

      # The declaration's adjacent literals: plain characters and \0 word breaks only, a \0
      # never before an octal digit, which C would read as one character.
      ALLOCATOR_DECLARATION = /^static const char ALLOCATOR_WORDS\[\] =((?:\s*"[^"\\]*(?:\\0(?![0-7])[^"\\]*)*")+);/

      # The allocator flags and their values, as boot_info.c's ALLOCATOR_WORDS holds them: one
      # string of NUL-separated words written as adjacent C literals, read here so that changing
      # a flag there changes the count every production boot checks. A declaration of another
      # shape, or an empty word (a \0 after the last word, or two together), raises rather than
      # being counted differently from C.
      def self.allocator_words(root)
        literals = File.read(File.join(root, BOOT_INFO))[ALLOCATOR_DECLARATION, 1]
        raise Error, "#{BOOT_INFO}: no ALLOCATOR_WORDS string of plain words" unless literals

        words = literals.scan(/"([^"]*)"/).join.split('\0', -1)
        raise Error, "#{BOOT_INFO}: ALLOCATOR_WORDS has an empty word" if words.any?(&:empty?)

        words
      end

      # Every word of ERTS's arguments that the manifest's own words do not add.
      def self.arguments_always(root) = ARGUMENTS_FIXED + allocator_words(root).size
      # The words of -erx given ROLE PERIPHERAL WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE
      # CLOCK COHERENT MAC, which the root adds for the device of each RECORD_UNITS unit but the host link's,
      # and of -erx device ROLE PERIPHERAL BASE SIZE LINE MARK CLOCK, the host link's UART's physical record
      # (docs/design-stopgap.md, "Device records").
      GIVEN_RECORD_WORDS = 14
      DEVICE_RECORD_WORDS = 9
      # The manifest unit that holds the host link's UART, which gives a device record only
      # when the boot sends erx.hostlink=1.
      HOSTLINK_UNIT = 'hostlink'
      # The names of the units the root gives device records. Each device of a held unit whose
      # role and compatible string match a row of boot_manifest.c's device_kinds table gets
      # one, and the manifest names each such unit after its row's record role word ("block",
      # "net", "gpu"), with one device in its placement; the host link's UART gets one too. A host
      # test keeps this list and that table's role words the same.
      RECORD_UNITS = ['block', 'net', 'gpu', HOSTLINK_UNIT].freeze
      # What a plain erx.arg word used to break: it joins the last flag's arguments.
      CONSOLE_PLAIN_WORD = 'erx.arg=plainword'
      # An output longer than any FIFO, so the driver writes it through the transmit check.
      CONSOLE_LONG_BYTES = 20_000
      # A tab and an escape sequence in a debug log record, typed as byte values.
      LOG_AFTER_HANDOFF = %(erx_log:debug(<<"after",9,"handoff",27,"[1m">>).\r)
      # The record LOG_AFTER_HANDOFF logs, as the console writes it: whole, ending in CR-LF,
      # with the tab and the escape byte as text, never as the bytes themselves. A log line
      # may land in the middle of the shell's output, between its "ok" and the newline after
      # it, or after the next prompt (docs/design-live.md, "Log lines and program output"),
      # so whatever precedes it on its line is not matched.
      LOG_AFTER_HANDOFF_RECORD = /#[0-9]+ [0-9]+\.[0-9]+ [a-z]+ .*after\\x09handoff\\x1B\[1m\r*\n\z/n
      # Processes of the system domain, registered by name, that every booted release runs at
      # the Erlang shell: init and the console as well as children of kernel_sup.
      SYSTEM_PROCESSES = %w[init code_server file_server_2 erx_console erx_watchdog].freeze
      # erlang:processes() at the Erlang shell: how many it lists, which of SYSTEM_PROCESSES it
      # misses, and the emulator's flavour, emu for the interpreter image (docs/design-runtime.md, R10).
      PROCESSES_EXPRESSION = '{processes,length(erlang:processes()),' \
                             "[N||N<-[#{SYSTEM_PROCESSES.join(',')}],not lists:member(whereis(N),erlang:processes())]," \
                             "erlang:system_info(emu_flavor)}.\r"
      # The release loads compiler and runtime_tools and starts neither (ReleaseFiles::LOAD_ONLY):
      # whether each is started, whether each is loaded, a module compiled from its forms and
      # called, and dbg's tracer started and stopped.
      LOAD_ONLY_EXPRESSION = '{ok,M,B}=compile:forms([{attribute,1,module,erx_probe},{attribute,1,export,[{f,0}]},' \
                             '{function,1,f,0,[{clause,1,[],[],[{atom,1,compiled}]}]}]),' \
                             'code:load_binary(M,"erx_probe",B),' \
                             '{load_only,[lists:keymember(A,1,application:which_applications())||A<-[compiler,runtime_tools]],' \
                             '[lists:keymember(A,1,application:loaded_applications())||A<-[compiler,runtime_tools]],' \
                             "erx_probe:f(),element(1,dbg:tracer()),dbg:stop()}.\r"

      # The collectors of erx_kernel_records, in the order the boot types them, each with how
      # its answer starts: one record, or a listing's status and records. The Erlang shell
      # writes each answer whole on one line with ~w (docs/design-stopgap.md, "Reporting
      # kernel objects"); the line typed for it starts io:format, so only the answer matches.
      KERNEL_RECORD_ANSWERS = { 'machine' => /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#\{/n, 'cpus' => /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{(?:ok|partial),\[/n,
                                'group' => /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#\{/n, 'budget' => /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#\{/n,
                                'threads' => /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{(?:ok|partial),\[/n }.freeze
      # The five records again, each without its {kernel,unsupported} attributes, so what is
      # left is what the stopgap reports: for a listing its status, its length and the
      # attributes any of its records reports.
      KERNEL_RECORD_SUMMARY = 'U=fun(R)->lists:sort([{K,V}||K:=V<-maps:get(attrs,R),V=/={kernel,unsupported}]) end,' \
                              'L=fun({S,Rs})->{S,length(Rs),lists:usort(lists:append([U(R)||R<-Rs]))} end,' \
                              'M=erx_kernel_records,io:format("~w~n",[{object_info,U(M:machine()),L(M:cpus()),' \
                              "U(M:group()),U(M:budget()),L(M:threads())}]).\r"

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @machine = Machine.development(platform)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
      end

      # The native_trace cell: the tracer's case (trace_checkpoints) at count CPUs under
      # accel, on an image of its own. A backend line that names a CPU names one the machine
      # has. No executor of the production image is pinned to one CPU, so its lines say
      # cpu=unknown; the CPUs named are kept with the cell for whoever pins one.
      def trace(accel:, count:, jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco, directory: 'build/production-image/trace')
        run = boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: false, points: Run.trace_checkpoints(machine: @machine),
                                        command_line: COMMAND_LINES[accel])
        serial = File.binread(run.fetch('serial_log'))
        problems = Run.trace_problems(serial)
        raise Error, "the tracer's case: #{problems.join('; ')}" unless problems.empty?

        cpus = Run.trace_cpus(serial)
        raise Error, "a backend trace line names CPU #{cpus.max} on a machine of #{count}" if cpus.any? { |cpu| cpu >= count }

        { "#{accel}-#{count}cpu" => { serial: run.fetch('serial_log'), cpus: cpus }.freeze }
      end

      # accels run the whole matrix: every boot below at each CPU count. TCG is not one of them;
      # it runs only the smoke, which smoke: true adds as SMOKE_CELLS: the plain boot to the command shell
      # at one CPU, and the deterministic transcript, without the boots that probe refusals, the
      # watchdog and the console.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true, smoke: false)
        unless (accels - PET_PROOF.keys).empty?
          raise Error, "production image: the whole matrix runs under #{PET_PROOF.keys.join(' ')}; TCG runs only the smoke"
        end

        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        check_device_paths
        built = image(fiasco)
        narrow = cpus.max > 1 ? image(fiasco, directory: 'build/production-image/narrow', manifest_source: Run.narrow_manifest(@root, platform: @machine.platform)) : nil
        full_matrix(accels, cpus, built, narrow).merge(smoke ? smoke_cells(built) : {})
      end

      # The transcript of a boot as far as ERTS gets, each line in order. The image is one
      # without test code, and the kernel's line names its archive's identity and flags,
      # so a test image's mark shows. The manifest line
      # carries the numbers the source says, so a root that misread it fails. ERTS's
      # arguments count each device record of a unit the system domain holds; a unit a
      # configured domain holds gives its record to that domain. hostlink is the boot's QemuPlan host link: a
      # plan of QemuPlan::NO_HOSTLINK sends no erx.hostlink=1, so the host link's UART gives
      # no record. memory_mib is the RAM QEMU gives the guest, which bootstrap reports. Schedulers are
      # one per CPU of the system's share on this machine. Erlang's init then boots the
      # release, `kernel` starts, and erx_console's slogan and its command shell's banner,
      # written through erx_pl011, prove the release ran that far. The command shell's
      # prompt ends no line, so no point names it. A test image (ProductionImage#build_test_image)
      # is booted only when test_image says so, and adds its banner line.
      def self.checkpoints(built, root:, watchdog:, cpus:, extra_arguments: 0, manifest_source:,
                           memory_mib:, hostlink: nil, test_image: false)
        source = manifest_source
        memory, baseline = %w[root_memory system_baseline].map { |key| source[/^\s*#{key} (\d+)$/, 1] }
        units = source.scan(/^unit /).size
        recorded = hostlink == QemuPlan::NO_HOSTLINK ? RECORD_UNITS - [HOSTLINK_UNIT] : RECORD_UNITS
        records = source.scan(/^unit (\w+)\n(?:  .*\n)*?  holder (\S+)$/)
                        .filter_map { |unit, holder| unit if holder == 'system' && recorded.include?(unit) }
                        .sum { |unit| unit == HOSTLINK_UNIT ? DEVICE_RECORD_WORDS : GIVEN_RECORD_WORDS }
        arguments = arguments_always(root) + records + source[/^\s*system_args "(.*)"$/, 1].split.size + extra_arguments
        count = schedulers(source, cpus: cpus)
        raise Error, 'a production boot refuses a test image' if built.test_code && !test_image
        raise Error, 'a test boot takes a test image' if test_image && !built.test_code

        image = /\Aerx: boot image build #{built.build_id} index #{built.index_hash} flags 0x#{built.flags.to_s(16)} archive /n
        identity = /\Aerx: root task: build #{built.build_id} index #{built.index_hash} entries [0-9]+\r?\n\z/n
        manifest = /\Aerx: root task: manifest root_memory #{memory} baseline #{baseline} units #{units} pool pages [0-9]+ image [0-9]+\r?\n\z/n
        [*Qemu.boot_transcript(memory_mib: memory_mib, test_image: test_image),
         point('image-identity', /\Aerx: boot image build/n, image, speaker: 'the kernel reports'),
         point('root-identity', /\Aerx: root task: build/n, identity),
         point('root-manifest', /\Aerx: root task: manifest/n, manifest),
         point('root-watchdog', /\Aerx: root task: watchdog/n, /\Aerx: root task: watchdog #{watchdog}\r?\n\z/n),
         point('erts-start', /\Aerx: erts: erl_start runs/n, /\Aerx: erts: erl_start runs, #{arguments} arguments\r?\n\z/n, seconds: 60),
         point('erts-executors', /\Aerx: erts: \d+ schedulers and/n, /\Aerx: erts: #{count} schedulers and #{count} dirty CPU schedulers hold executor slots\r*\n\z/n, seconds: 60),
         SLOGAN, RELEASE_SHELL].freeze
      end

      # Schedulers are one per CPU of the system's share on this machine.
      def self.schedulers(manifest_source, cpus:)
        share = manifest_source[/^share system\n(?:  .*\n)*?  cpuset (\d+)$/, 1].to_i
        (share & ((1 << cpus) - 1)).to_s(2).count('1')
      end

      # A machine at rest at the Erlang shell, with the group's report on: once the prompt is
      # up, a line of the report says every executor parked. The report writes a line only when
      # the counts change, and a fast machine may park everything before the banner, so the
      # person at the console starts the Erlang shell and keeps one scheduler busy for half a
      # second first: the report must then show it wake and every executor park again. The
      # report writes beside the console driver, so the slogan and the two shells' banners are
      # looked for anywhere in a line, and its line may follow an unended prompt.
      def self.idle_checkpoints(cpus:, root:, machine:)
        # Each scheduler and each dirty CPU scheduler holds an executor slot.
        executors = 2 * schedulers(machine.platform.manifest_source(root), cpus: cpus)
        [*Qemu.boot_transcript(memory_mib: machine.memory_mib),
         { name: 'release-slogan', pattern: %r{Erlang/OTP 29 }n, seconds: 240 }.freeze,
         { name: 'release-shell', pattern: /#{Regexp.escape(COMMAND_SHELL_BANNER)}/n, seconds: 60, type: ERL_LINE }.freeze,
         { name: 'erlang-shell', pattern: /Eshell V/n, seconds: 60, type: BUSY_EXPRESSION }.freeze,
         # The report's bytes may fall inside the driver's, so the line is looked for at its end only.
         { name: 'idle-parked', pattern: /erx: root task: group: parked #{executors} of #{executors}\r*\n\z/n,
           seconds: EVAL_SECONDS }.freeze].freeze
      end

      # The kernel-object records at the Erlang shell, at the statuses design-stopgap.md's
      # "Reporting kernel objects" table gives. Of the attributes only the kernel could
      # report, just these are ok: the machine's build, boot_value, cpus_online and uptime,
      # and the system group's parked and ready. The group's cpuset would be ok once a set
      # is configured, and nothing configures the system group's. The machine's memory_total and
      # memory_free and the budget's used are partial, with reporter liberx_pool, and above
      # zero. Every other attribute is unsupported with reporter
      # kernel, and the CPUs and the system domain's threads are listed whole. Each answer
      # types the next collector, the last types the summary, and the summary's line must
      # be exactly that.
      def self.kernel_record_checkpoints(cpus:, machine:)
        typed = [*KERNEL_RECORD_ANSWERS.keys.map { |call| %(io:format("~w~n",[erx_kernel_records:#{call}()]).\r) },
                 KERNEL_RECORD_SUMMARY]
        answers = KERNEL_RECORD_ANSWERS.zip(typed.drop(1)).map do |(call, start), type|
          { name: "kernel-record-#{call}", pattern: start, seconds: EVAL_SECONDS, type: type }.freeze
        end
        [*Qemu.boot_transcript(memory_mib: machine.memory_mib), SLOGAN,
         RELEASE_SHELL.merge(type: ERL_LINE).freeze, ERLANG_SHELL.merge(type: typed.first).freeze, *answers,
         { name: 'kernel-record-summary', pattern: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{object_info,/n, seconds: EVAL_SECONDS,
           verify: whole_line(kernel_record_line(cpus: cpus), speaker: 'the kernel records read') }.freeze].freeze
      end

      # The summary line KERNEL_RECORD_SUMMARY writes on a machine of cpus CPUs: the fixed
      # text escaped, with a pattern only where a number may vary.
      def self.kernel_record_line(cpus:)
        any_number = '[0-9]+'
        positive = '[1-9][0-9]*'
        text = ->(fixed) { Regexp.escape(fixed) }
        ok = ->(key, value) { "#{text.call("{#{key},{kernel,{ok,")}#{value}#{text.call('}}}')}" }
        # ~w writes a binary as its bytes: the build identifier's sixteen lower-case hex digits.
        hex_digit = '(?:4[89]|5[0-7]|9[7-9]|10[0-2])'
        build_id = "<<#{hex_digit}(?:,#{hex_digit}){15}>>"
        pool = ->(key) { text.call("{#{key},{{stopgap,liberx_pool},{partial,") + positive + text.call('}}}') }
        machine = text.call('[') + [ok.call('boot_value', '(?:normal|trial|unknown)'), ok.call('build', build_id),
                                    ok.call('cpus_online', cpus), pool.call('memory_free'), pool.call('memory_total'),
                                    ok.call('uptime', positive)].join(',') + text.call(']')
        cpu_listing = text.call("{ok,#{cpus},[]}")
        group = text.call('[') + ok.call('parked', any_number) + ',' + ok.call('ready', any_number) + text.call(']')
        budget = text.call('[{used,{{stopgap,liberx_pool},{partial,') + positive + text.call('}}}]')
        threads = text.call('{ok,') + positive + text.call(',[]}')
        summary = text.call('{object_info,') + [machine, cpu_listing, group, budget, threads].join(',') + text.call('}')
        /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{summary}\r*\n\z/n
      end
      private_class_method :kernel_record_line

      # A person at the serial console. The first line, erl, is typed at the boot's development
      # warning, before the driver starts, so the FIFO holds it when the driver takes the UART,
      # and the command shell reads it at its first prompt and starts the Erlang shell. At the
      # Erlang shell's banner the person types a sum, and each answer then types the next
      # line: Ctrl-G, whose menu Esc leaves for the Erlang shell again, a line with a mistake
      # rubbed out, under which the sum is 4 where the mistake is
      # a syntax error, an output longer than any FIFO, a debug log record, what
      # erlang:processes() lists, and a module compiled and a tracer started with compiler
      # and runtime_tools loaded and neither started, and an rc line the command shell's
      # evaluator runs with its Erlang commands, and erx:i(), whose machine rows report build,
      # boot_value, cpus_online and uptime under Fiasco and whose budget's used the root pool
      # reports partial, with the pool's scope below the tables, and the same statuses in
      # /proc: ls and cat through the command shell's evaluator, then file:read_file/1 of a
      # process's status file, which is size 0 and read to its end as stock reads one.
      def self.console_checkpoints(machine:)
        boot = Qemu.boot_transcript(memory_mib: machine.memory_mib).map do |point|
          point.fetch(:name) == 'development-warning' ? point.merge(type: ERL_LINE).freeze : point
        end
        raise Error, 'the boot transcript has no development warning to type at' unless boot.any? { |point| point.key?(:type) }

        [*boot, SLOGAN,
         console_point('release-shell', RELEASE_SHELL.fetch(:pattern)),
         console_point('shell', ERLANG_SHELL.fetch(:pattern), type: "1+1.\r"),
         console_point('sum-echo', /1\+1\.\r*\n\z/n),
         console_point('sum-answer', /\A2\r*\n\z/n, type: CTRL_G),
         console_point('ctrl-g-menu', CTRL_G_MENU, type: ESC),
         console_point('menu-left', MENU_LEFT, type: "1+2\x7f3.\r"),
         console_point('edit-answer', /\A4\r*\n\z/n, type: "io:put_chars(lists:duplicate(#{CONSOLE_LONG_BYTES},$x)),io:nl().\r"),
         console_point('long-output', /x{#{CONSOLE_LONG_BYTES}}/n),
         console_point('long-answer', /\Aok\r*\n\z/n, type: LOG_AFTER_HANDOFF),
         # A record logged once the driver owns the UART: the console reads it and writes it.
         console_point('log-after-handoff', LOG_AFTER_HANDOFF_RECORD, type: PROCESSES_EXPRESSION),
         # The echo of the line reads {processes,length, so only the answer matches.
         console_point('processes', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{processes,[0-9]/n,
                       whole: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{processes,[1-9][0-9]*,\[\],emu\}\r*\n\z/n, type: LOAD_ONLY_EXPRESSION),
         # The echo of the line starts {ok,M,B}=, so only the answer matches.
         console_point('load-only', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{load_only,/n,
                       whole: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{load_only,\[false,false\],\[true,true\],compiled,ok,ok\}\r*\n\z/n,
                       type: RC_EXPRESSION),
         # The echo of the line holds `echo rc:`, so only the output starts with rc:.
         console_point('rc-output', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?rc: /n, whole: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?rc: 2 hello world f \|\r*\n\z/n),
         console_point('rc-ending', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{ok,<<>>\}\r*\n\z/n, type: "erx:i().\r"),
         # The echo of the line holds erx:i(), so only the machine record's title matches.
         console_point('inspect-machine', %r{\A/  machine\r*\n\z}n),
         console_point('inspect-memory', /\A  memory_total +root pool +\[partial\]\r*\n\z/n),
         console_point('inspect-uptime', /\A  uptime +kernel +[1-9][0-9]*\r*\n\z/n),
         console_point('inspect-used', /\A  used +root pool +\[partial\]\r*\n\z/n),
         console_point('inspect-processes', %r{\A/processes  [1-9][0-9]* entries\r*\n\z}n),
         console_point('inspect-scope', /\Aroot pool: pages of the root's pool:/n),
         console_point('inspect-answer', /\Aok\r*\n\z/n, type: PROC_EXPRESSION),
         # ls -1 /proc, sorted, then the console process's status, the machine's and the system
         # domain's budget's, each attribute a line of name, value and reporter. The console's
         # terminal-less rendering writes each tab of the file as CHT, ESC [ I.
         console_point('proc-ls-domains', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?domains\r*\n\z/n),
         console_point('proc-ls-processes', /\Aprocesses\r*\n\z/n),
         console_point('proc-ls-status', /\Astatus\r*\n\z/n),
         console_point('proc-process-domain', /\Adomain#{TAB}4#{TAB}service\r*\n\z/n),
         console_point('proc-process-name', /\Aregistered_name#{TAB}erx_console#{TAB}runtime\r*\n\z/n),
         console_point('proc-machine-build', /\Abuild#{TAB}[0-9a-f]{16}#{TAB}kernel\r*\n\z/n),
         console_point('proc-machine-memory', /\Amemory_total#{TAB}\[partial\]#{TAB}root pool\r*\n\z/n),
         console_point('proc-machine-uptime', /\Auptime#{TAB}[1-9][0-9]*#{TAB}kernel\r*\n\z/n),
         console_point('proc-machine-boot-value', /\Aboot_value#{TAB}(?:normal|trial|unknown)#{TAB}kernel\r*\n\z/n),
         console_point('proc-budget-used', /\Aused#{TAB}\[partial\]#{TAB}root pool\r*\n\z/n),
         console_point('proc-ending', /\A\{ok,<<>>\}\r*\n\z/n, type: PROC_READ_EXPRESSION),
         # The echo of the line holds {proc_read, so only the answer matches.
         console_point('proc-read', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{proc_read,/n,
                       whole: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{proc_read,true,true,true\}\r*\n\z/n, type: TOP_EXPRESSION),
         # top's header through the inspector with the session's facet: the run queue and the
         # uptime ok; the pool's memory and the root's used partial, each line's numbers all
         # the pool's, so its label names the pool; the rest of the budget unsupported, so `-`.
         # The echo holds top -b, so only the header matches.
         console_point('top-first', /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?run queue: [0-9]+;  up /n,
                       whole: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?run queue: [0-9]+;  up 0\+00:[0-5][0-9]:[0-5][0-9]    [0-2][0-9]:[0-5][0-9]:[0-5][0-9]\r*\n\z/n),
         console_point('top-states', /\A[1-9][0-9]* processes: /n),
         console_point('top-memory', /\AMem \(root pool\): [1-9][0-9]{0,3}[KMG] Total, [0-9]{1,4}[KMG] Free\r*\n\z/n),
         console_point('top-budget',
                       /\ADomain 4 budget \(root pool\): [1-9][0-9]{0,3}[KMG] Used, - Guarantee \[unsupported\], - Cap \[unsupported\]\r*\n\z/n)].freeze
      end

      # A line of the console's transcript, what the person types once it is seen, and the
      # whole line it must be, whose mismatch raises with the line.
      def self.console_point(name, pattern, type: nil, whole: nil)
        verify = whole && whole_line(whole, speaker: 'the console answered')
        { name: name, pattern: pattern, seconds: EVAL_SECONDS, **{ type: type, verify: verify }.compact }.freeze
      end
      private_class_method :console_point

      # The tracer's case on four CPUs (docs/design-stopgap.md, Verification, "Trace on four
      # CPUs"). At the Erlang shell the person spawns a workload, which waits for a message
      # or 20 ms and loops, and starts erx:trace over it with the kernel's rows; the shell
      # prints {workload, Pid}. The kernel row is one unsupported line reported by kernel;
      # a message sent to the workload, then the workload's first erts in, not late; then
      # the trace is stopped. Each checkpointed trace line is checked whole; the shell's
      # line editor may redraw its prompt and pending input, ending in ESC [J, before a
      # line another process writes. Run#trace checks the rest on the serial log
      # (trace_problems).
      TRACE_START = 'W=spawn(fun F()->receive _->F() after 20->F() end end),' \
                    "{ok,R}=erx:trace(\#{select=>[W],kernel=>true}),{workload,W}.\r"
      TRACE_SEND = "W!hello,sent.\r"
      TRACE_STOP = "erx:trace_stop(R),trace_stopped.\r"
      TRACE_REDRAW = '(?:[^\n]*\e\[J)?'
      TRACE_TIME = "\\A#{TRACE_REDRAW} *[0-9]+\\.[0-9]{9}".freeze
      def self.trace_checkpoints(machine:)
        boot = Qemu.boot_transcript(memory_mib: machine.memory_mib).map do |point|
          point.fetch(:name) == 'development-warning' ? point.merge(type: ERL_LINE).freeze : point
        end
        [*boot, SLOGAN,
         console_point('release-shell', RELEASE_SHELL.fetch(:pattern)),
         console_point('shell', ERLANG_SHELL.fetch(:pattern), type: TRACE_START),
         console_point('trace-unsupported', / kernel unsupported /n,
                       whole: /#{TRACE_TIME} kernel unsupported \[kernel\]\r*\n\z/n, type: TRACE_SEND),
         console_point('trace-workload-in', / erts in /n,
                       whole: %r{#{TRACE_TIME} erts in pid=<0\.[0-9]+\.0> domain=4 mfa=[^ ]+ \[runtime\]\r*\n\z}n,
                       type: TRACE_STOP),
         console_point('trace-stopped', /\A(?:[^\n]*\e\[J)?(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?trace_stopped\r*\n\z/n)].freeze
      end

      # What the tracer's case got wrong on its serial log, beyond the checkpoints: the
      # kernel row's unsupported line exactly once; a backend park followed by a wake of the
      # same slot; and the workload's pid, as the shell printed it, on an erts in that is not
      # late, and on every erts line, since the trace selects the workload alone.
      def self.trace_problems(serial)
        lines = serial.b.lines
        unsupported = lines.count { |line| line.include?(' kernel unsupported [kernel]') }
        workload = serial.b[/\{workload,(<0\.[0-9]+\.0>)\}/n, 1]
        traced = lines.filter_map { |line| line[/ erts [a-z_]+ pid=(<[0-9.]+>) /n, 1] }.uniq
        on_time_in = / erts in pid=#{Regexp.escape(workload.to_s)} .*\[runtime\]\r*$/n
        [("#{unsupported} unsupported lines, not one" unless unsupported == 1),
         ('no backend park followed by a wake of the same slot' unless park_then_wake?(lines)),
         ('the shell printed no {workload, Pid}' unless workload),
         ("erts lines name #{traced.join(' ')}, not the workload alone" unless traced == [workload]),
         ('no erts in of the workload that is not late' unless lines.any? { |line| line.match?(on_time_in) })].compact
      end

      # Whether some backend wake names a slot an earlier backend park named.
      def self.park_then_wake?(lines)
        parked = Set.new
        lines.any? do |line|
          if (slot = line[/ backend park .*slot=([0-9]+) /n, 1])
            parked << slot
            false
          else
            parked.include?(line[/ backend wake .*slot=([0-9]+) /n, 1])
          end
        end
      end
      private_class_method :park_then_wake?

      # The CPUs the backend's trace lines name, from a serial log: the integers, since a
      # record whose writer's affinity names no one CPU says cpu=unknown.
      def self.trace_cpus(serial)
        serial.b.scan(/ backend [a-z_]+ .* cpu=([0-9]+) thread=[0-9]+ space=[0-9]+ \[liberx trace\]/n)
              .flatten.map { |cpu| Integer(cpu, 10) }.uniq.sort
      end

      # The release's boot with its children named, then the line that outlived the deadlines.
      # init's -eval writes beside the command shell, so a line of its may follow the unended prompt.
      def self.survival_checkpoints(seconds:, machine:)
        children = KERNEL_CHILDREN.join(',')
        [*Qemu.boot_transcript(memory_mib: machine.memory_mib),
         SLOGAN,
         point('kernel-children', /\A(?:% )?\[[a-z0-9_,]+\]\r*\n\z/n, /\A(?:% )?\[#{children}\]\r*\n\z/n, seconds: EVAL_SECONDS),
         { name: 'past-the-deadlines', pattern: /\A(?:% )?past_the_deadlines\r*\n\z/n, seconds: seconds + 60 }.freeze].freeze
      end

      # A machine with no more RAM than root_memory: the same image boots to the root, which
      # says so and ends the machine before anything would start.
      def self.refusal_checkpoints
        [*Qemu.boot_transcript(memory_mib: TOO_LITTLE_MEMORY_MIB),
         { name: 'root-refusal', pattern: /\Aerx: root task refused the boot: manifest: root_memory is more than/n, seconds: 30 }.freeze].freeze
      end

      # A kernel command line the root will not take: it says so and ends the machine.
      def self.command_line_refusal_checkpoints(machine:)
        [*Qemu.boot_transcript(memory_mib: machine.memory_mib),
         { name: 'root-refusal', pattern: /\Aerx: root task refused the boot: the kernel command line/n, seconds: 30 }.freeze].freeze
      end

      # A device tree that names the console's UART by another path than the manifest's
      # console, through an alias and with options after it: the root says both paths
      # and ends the machine.
      def self.stdout_path_refusal_checkpoints(machine:)
        [*Qemu.boot_transcript(memory_mib: machine.memory_mib),
         { name: 'root-refusal', seconds: 30,
           pattern: %r{\Aerx: root task refused the boot: manifest: the console /pl011@9000000 is not the node /chosen/stdout-path names, #{Regexp.escape(SEEDED_STDOUT_NODE)}\r?\n}n }.freeze].freeze
      end

      def self.point(name, pattern, whole, seconds: 30, speaker: 'the root task reports')
        { name: name, pattern: pattern, seconds: seconds, verify: whole_line(whole, speaker: speaker) }.freeze
      end
      private_class_method :point

      # Checkpoints whose one root-manifest point also holds what the boot kept besides the
      # archive to the packer's estimate (Manifest::RootStartup.check_boot): from the pool
      # pages and the root's image the line reports, the machine's RAM, fiasco_reserve and
      # root_withheld, the archive in whole pages, and the devices' memory the manifest
      # declares, which sized the boot's contiguous pool. A boot that keeps more fails here,
      # before an archive the packer passed fails at the root. Points without exactly one
      # root-manifest point are refused, so the check cannot silently drop out.
      def self.kept_checkpoints(points, built:, machine:)
        unless points.count { |point| point.fetch(:name) == 'root-manifest' } == 1
          raise Error, 'the boot check needs exactly one root-manifest checkpoint'
        end

        page = Manifest::RootStartup::PAGE_BYTES
        archive_bytes = (File.size(built.archive) + page - 1) / page * page
        figures = Manifest::RootStartup.archive_machine(machine.record)
                                       .merge(dma_memory: built.report.fetch('manifest').fetch('dma_memory'))
        points.map do |point|
          next point unless point.fetch(:name) == 'root-manifest'

          whole = point.fetch(:verify)
          verify = lambda do |text|
            whole.call(text)
            reported = text.match(/ pool pages (?<pool>\d+) image (?<image>\d+)\r?\n\z/n)
            raise Error, "the root task reports no pool pages and image: #{text.inspect}" if reported.nil?

            Manifest::RootStartup.check_boot(archive_bytes: archive_bytes, pool_pages: reported[:pool].to_i,
                                             image_bytes: reported[:image].to_i, **figures)
          end
          point.merge(verify: verify).freeze
        end.freeze
      end

      # A checkpoint's verifier: the line it selected must match whole, or it raises with the line.
      def self.whole_line(whole, speaker:)
        ->(text) { raise Error, "#{speaker} #{text.inspect}" unless whole.match?(text) }
      end
      private_class_method :whole_line

      private

      # SMOKE_CELLS under TCG: the plain boot to the command shell at one CPU, then the transcript.
      # The plain boot is of the website's machine, one UART, the console's: one serial line and
      # no erx.hostlink=1, so the root hands no host link record and erx_hostlink starts nothing
      # (docs/design-stopgap.md, "The command line"). A record for the absent UART faults the
      # root task under TCG at erx_pl011's first read, as on the website; under HVF the same read
      # does not fault, so only this boot shows it. HVF's boots keep the host link.
      # Each name sits beside the boot that earns it, so dropping a boot drops its cell, and
      # the gate then marks the declared cell not_run.
      def smoke_cells(built)
        { 'tcg-1cpu' => smoke_boot(built), 'tcg-deterministic' => deterministic(built) }
      end

      def smoke_boot(built)
        hostlink = QemuPlan::NO_HOSTLINK
        points = production_checkpoints(built, watchdog: watchdog_pattern('tcg'), cpus: 1, hostlink: hostlink)
        full = boot('tcg', 1, built, memory_mib: @machine.memory_mib, points: points, machine_end: false, command_line: COMMAND_LINES['tcg'],
                                       hostlink: hostlink)
        { serial: full.fetch('serial_log'), seconds: full.fetch('elapsed_seconds') }.freeze
      end

      # The watchdog numbers the boot reports: TCG's from COMMAND_LINES, and under HVF the
      # kernel's defaults, whatever they are.
      def watchdog_pattern(accel) = accel == 'tcg' ? TCG_WATCHDOG : '[0-9]+,[0-9]+,[0-9]+'

      def full_matrix(accels, cpus, built, narrow)
        accels.product(cpus).to_h do |accel, count|
          points = production_checkpoints(built, watchdog: watchdog_pattern(accel), cpus: count)
          full = boot(accel, count, built, memory_mib: @machine.memory_mib, points: points, machine_end: false, command_line: COMMAND_LINES[accel])
          if count == cpus.first
            boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: true, command_line: UNKNOWN_WORD_LINE,
                                      points: Run.command_line_refusal_checkpoints(machine: @machine))
            boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: true, dtb: seeded_stdout_tree(accel, count, built),
                                      points: Run.stdout_path_refusal_checkpoints(machine: @machine))
          end
          prove_pet(accel, count, built) if count == cpus.first
          boot_narrow(accel, count, narrow) if narrow && count == cpus.max
          console_boot(accel, count, built)
          hostlink_boot(accel, count, built) if count == cpus.first
          files_boot(accel, count, built) if count == cpus.first
          reload_boot(accel, count, built) if count == cpus.max && count >= 4
          parked_log_boot(accel, count, built)
          idle_boot(accel, count, built)
          kernel_records_boot(accel, count, built)
          # This boot's transcript is its whole result: it raises if the refusal is missing.
          boot(accel, count, built, memory_mib: TOO_LITTLE_MEMORY_MIB, points: Run.refusal_checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: full.fetch('serial_log'), seconds: full.fetch('elapsed_seconds') }.freeze]
        end
      end

      # Two boots in deterministic mode, to the command shell, whose transcripts must be the same
      # byte for byte (DeterministicTranscript); the recipe is one CPU under TCG. The cell
      # carries how many lines the two agreed on.
      def deterministic(built)
        points = production_checkpoints(built, watchdog: 'off', cpus: 1, extra_arguments: DETERMINISTIC_LINE.scan('erx.arg=').size)
        first, second = Array.new(2) do
          report = boot('tcg', 1, built, memory_mib: @machine.memory_mib, machine_end: false, command_line: DETERMINISTIC_LINE, points: points)
          File.binread(report.fetch('serial_log'))
        end
        { lines: DeterministicTranscript.compare(first, second) }.freeze
      end

      # The pet at work: the machine outlives its deadlines, and once erx_watchdog stops being
      # scheduled it ends, with the watchdog's own crash record. Neither alone is the proof: a
      # watchdog that never fires passes the first, and one that ignores pets the second.
      def prove_pet(accel, count, built)
        proof = PET_PROOF.fetch(accel)
        seconds = proof.fetch(:boot) + PET_MARGIN_SECONDS
        line = "erx.watchdog=#{proof.values_at(:period, :pet, :boot).join(',')} erx.arg=-eval"
        expression = "#{CHILDREN_EXPRESSION},timer:sleep(#{seconds * 1000}),erlang:display(past_the_deadlines)."
        boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: false, points: Run.survival_checkpoints(seconds: seconds, machine: @machine),
                                  command_line: "#{line} erx.arg=#{expression}")
        window = proof.fetch(:pet) + proof.fetch(:period) + PET_MARGIN_SECONDS
        stopped = boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: true, command_line: "#{line} erx.arg=#{STOP_PET}",
                                            points: [*Qemu.boot_transcript(memory_mib: @machine.memory_mib), SLOGAN,
                                                     { name: 'pet-stopped', pattern: /\A(?:% )?pet_stopped\r*\n\z/n, seconds: EVAL_SECONDS }.freeze,
                                                     { name: 'watchdog-fired', pattern: /#{Regexp.escape(CrashFrame::BEGIN_MARKER)}/n, seconds: window }.freeze])
        judge_missed_pet(File.binread(stopped.fetch('serial_log')))
        judge_missed_pet_time(stopped.fetch('checkpoints'), proof)
      end

      # An rc line that the command shell runs with its Erlang commands, in a directory of
      # its own under /tmp: redirections to a file, a pipeline, substitutions, ls and ps.
      # Its one line of output names the line count, the file's words, ls's one name and
      # the statuses of `ps | cat`, then the Erlang shell prints how the source ended.
      # A tab of a file as the console writes it: the byte, or CHT where it renders tabs.
      TAB = '(?:\t|\e\[I)'
      # /proc through the command shell's evaluator: the console process's directory is its
      # proc_id, D.N.S, with D the system domain's 4 and N.S the numbers of its local pid.
      PROC_EXPRESSION = 'P=["4",lists:droplast(string:find(pid_to_list(whereis(erx_console)),"."))],' \
                        'erx_shell_script:run(["ls -1 /proc; cat /proc/processes/",P,' \
                        '"/status /proc/status /proc/domains/4/budget/status"]).' "\r"
      # One display of top, its process table cut to one row.
      TOP_EXPRESSION = 'erx_shell_script:run("top -b 1").' "\r"
      # The same status file through file:read_file/1: every line of it is a field escape's
      # name, value and reporter, and the console's line says so. B is LOAD_ONLY_EXPRESSION's.
      PROC_READ_EXPRESSION = '{ok,PB}=file:read_file(["/proc/processes/",P,"/status"]),' \
                             '{proc_read,binary:match(PB,<<"registered_name\\terx_console\\truntime\\n">>)=/=nomatch,' \
                             'binary:last(PB)=:=$\\n,' \
                             'lists:all(fun(L)->length(binary:split(L,<<"\\t">>,[global]))=:=3 end,' \
                             'binary:split(PB,<<"\\n">>,[global,trim_all]))}.' "\r"
      RC_EXPRESSION = 'erx_shell_script:run(<<"mkdir /tmp/rc; cd /tmp/rc; echo hello > f; echo world >> f; ' \
                      'x=`{cat f | cat}; y=`{ls | cat}; ps | cat > p; s=$status; ' \
                      'echo rc: $#x $x $y $s">>).' "\r"

      # The record comes about the pet deadline D after the suspension, not at once and not
      # long after: the first would mean a watchdog that is not waiting for pets, the second
      # one that needs the machine's help to end it.
      def judge_missed_pet_time(checkpoints, proof)
        at = ->(name) { checkpoints.find { |point| point.fetch('name') == name }.fetch('elapsed_seconds') }
        waited = at.call('watchdog-fired') - at.call('pet-stopped')
        earliest = proof.fetch(:pet) - PET_EARLY_SECONDS
        latest = proof.fetch(:pet) + proof.fetch(:period) + PET_MARGIN_SECONDS
        return if waited.between?(earliest, latest)

        raise Error, "a stopped pet ended the machine #{waited.round(1)} seconds after it stopped, not within #{earliest} to #{latest}"
      end

      # The host link end to end (HostlinkGuest), from this host over QEMU's socket to the
      # system domain's second UART, once the boot has reached the command shell. The guest
      # must report this image's build in its hello.
      def hostlink_boot(accel, count, built)
        points = production_checkpoints(built, watchdog: watchdog_pattern(accel), cpus: count)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, image: built.single, memory_mib: @machine.memory_mib, checkpoints: points, machine_end: false,
                 command_line: COMMAND_LINES[accel], directory: hostlink_directory(accel),
                 link: ->(socket) { HostlinkGuest.call(socket, build: built.build_id) }, link_seconds: HostlinkGuest::SECONDS)
      end

      # M4's files check (FilesGuest): the guest boots writing a file into /tmp with tmp
      # among its host link's files trees, and the host reads it through tools/erx files.
      def files_boot(accel, count, built)
        line = [COMMAND_LINES[accel], FilesGuest.command_line].compact.join(' ')
        points = production_checkpoints(built, watchdog: watchdog_pattern(accel), cpus: count,
                                        extra_arguments: FilesGuest::ARGUMENTS.size)
        directory = File.join(@root, 'build/qemu', "fl-#{accel}-#{Process.pid}")
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, image: built.single, memory_mib: @machine.memory_mib, checkpoints: points, machine_end: false,
                 command_line: line, directory: directory, link_seconds: FilesGuest::SECONDS,
                 link: lambda { |socket|
                   FilesGuest.call(socket, root: @root, build: built.build_id,
                                           serial: File.join(File.dirname(socket), 'serial.log'))
                 })
      end

      # M4's reload and bad-hash checks (ReloadGuest): the guest boots with the probe's
      # start expression, and the host installs the probe and reloads the subject in a loop.
      def reload_boot(accel, count, built)
        compile = ErlangCompile.for_tree(root: @root)
        sources = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/reload-probe'))
        modules = ReloadGuest.compile(compile: compile, root: @root, directory: sources,
                                      versions: ReloadGuest::VERSIONS)
        line = [COMMAND_LINES[accel], "erx.arg=-eval erx.arg=#{ReloadGuest::START}"].compact.join(' ')
        points = production_checkpoints(built, watchdog: watchdog_pattern(accel), cpus: count, extra_arguments: 2)
        directory = File.join(@root, 'build/qemu', "rl-#{accel}-#{Process.pid}")
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, image: built.single, memory_mib: @machine.memory_mib, checkpoints: points, machine_end: false,
                 command_line: line, directory: directory, link_seconds: ReloadGuest::SECONDS,
                 link: lambda { |socket|
                   ReloadGuest.call(socket, build: built.build_id, modules: modules,
                                            serial: File.join(File.dirname(socket), 'serial.log'), cpus: count)
                 })
      end

      # A run directory whose socket path fits a UNIX socket's (QemuPlan::SOCKET_PATH_MAX).
      def hostlink_directory(accel) = File.join(@root, 'build/qemu', "hl-#{accel}-#{Process.pid}")

      def console_boot(accel, count, built)
        boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: false, points: Run.console_checkpoints(machine: @machine),
                                  command_line: [COMMAND_LINES[accel], CONSOLE_PLAIN_WORD].compact.join(' '))
      end

      # The record is written after the console is suspended, so only the end path can put it
      # on the line before the machine ends. After the suspend the expression calls only BIFs
      # and modules already loaded, so erx_log is loaded first. The console's first poll loads
      # erx_log too, and the code server lets one process load a module while every other
      # caller waits for it, so a console suspended in the middle of that load would leave
      # erx_log:debug waiting forever, with no record, no halt and the watchdog still petted.
      # The text is "parked", tab, "at", tab, "end", as code points, since the line holds no
      # quote.
      def parked_log_boot(accel, count, built)
        expression = '{module,erx_log}=code:ensure_loaded(erx_log),' \
                     'erlang:suspend_process(whereis(erx_console)),' \
                     'erx_log:debug([112,97,114,107,101,100,9,97,116,9,101,110,100]),erlang:halt().'
        boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: true,
                                  command_line: [COMMAND_LINES[accel], "erx.arg=-eval erx.arg=#{expression}"].compact.join(' '),
                                  points: [*Qemu.boot_transcript(memory_mib: @machine.memory_mib), SLOGAN,
                                           { name: 'parked-at-end', pattern: /debug .*parked\\x09at\\x09end\r*\n\z/n,
                                             seconds: EVAL_SECONDS }.freeze])
      end

      def idle_boot(accel, count, built)
        boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: false, points: Run.idle_checkpoints(cpus: count, root: @root, machine: @machine),
                                  command_line: [COMMAND_LINES[accel], GROUP_REPORT_WORD].compact.join(' '))
      end

      # The kernel-object records, read at the Erlang shell (Run.kernel_record_checkpoints).
      def kernel_records_boot(accel, count, built)
        boot(accel, count, built, memory_mib: @machine.memory_mib, machine_end: false, points: Run.kernel_record_checkpoints(cpus: count, machine: @machine),
                                  command_line: COMMAND_LINES[accel])
      end

      def judge_missed_pet(serial)
        result = CrashFrame.read(serial)
        raise Error, CrashFrame.report(result).join(' / ') unless result.status == :valid

        cause = result.record.fetch('cause')
        raise Error, "a stopped pet ended the machine with cause #{cause}" unless cause == CrashFrame::CODEC.member('crash_cause', 'watchdog')
      end

      # Run.checkpoints for a boot of the production image on this suite's machine, whose
      # root-manifest line also holds the boot to what the packer counts (Run.kept_checkpoints).
      def production_checkpoints(built, **options)
        points = Run.checkpoints(built, root: @root, manifest_source: @machine.platform.manifest_source(@root),
                                        memory_mib: @machine.memory_mib, **options)
        Run.kept_checkpoints(points, built: built, machine: @machine)
      end

      def boot(accel, count, built, memory_mib:, points:, machine_end:, command_line: nil, dtb: nil, hostlink: nil)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, image: built.single, memory_mib: memory_mib, checkpoints: points, machine_end: machine_end,
                 command_line: command_line, dtb: dtb, hostlink: hostlink)
      end

      # The seeded tree's name for the console's PL011, which its stdout-path names through
      # the alias SEEDED_STDOUT_ALIAS.
      SEEDED_STDOUT_NODE = '/uart@9000000'
      SEEDED_STDOUT_ALIAS = 'serial0'

      # QEMU's own tree for the machine a boot gets, with the console's node renamed
      # (seed_stdout_path). -dtb hands a boot this tree in place of the one QEMU would write.
      # The dump's plan has the host link, as the boot that takes the tree does, so the tree has
      # the host link's UART and its /chosen/bootargs carry erx.hostlink=1.
      def seeded_stdout_tree(accel, count, built)
        argv = QemuPlan.argv(platform: @machine.platform, accel: accel, image: File.expand_path(built.single), serial: '/dev/null', cpus: count,
                            memory_mib: @machine.memory_mib, program: @qemu)
        ProductionImage.seeded_tree(runner: @runner, argv: argv, path: File.join(@root, 'build/production-image/device-tree', "#{accel}-#{count}cpu-stdout.dtb")) do |listing|
          ProductionImage.seed_stdout_path(listing, node: '/pl011@9000000', renamed: SEEDED_STDOUT_NODE, alias_name: SEEDED_STDOUT_ALIAS)
        end
      end

      # The production image without its session template, since this suite's cells type
      # at the system shell (ProductionImage.without_sessions), unless manifest_source names another.
      def image(fiasco, directory: 'build/production-image/boot', manifest_source: nil)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, directory))
        manifest_source ||= ProductionImage.sessionless_manifest(@root, platform: @machine.platform)
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine, fiasco: fiasco)
                       .build(directory: directory, manifest_source: manifest_source)
      end

      # The manifest with the system share on the machine's first two CPUs only. A boot of it
      # on a larger machine tells a scheduler count taken from the share and the online CPUs
      # together from one taken from the online CPUs alone, which the manifest's own cpuset,
      # every CPU the runs have, cannot. Every share is narrowed (Run.narrow_share), so the
      # configured domains' grants, the storage domain's of users and the web domain's of
      # web, still fit the system share, as the domain library requires
      # (docs/design-system.md, "The domain library").
      # Two CPUs' system share less its reserve holds one grant of users, not two, so the
      # narrow manifest leaves out the network domain (NARROW_DROPPED), whose net unit the
      # narrow cells, which boot without a network device, do not use. The manifest check
      # and the library's planner judge the result whole.
      def self.narrow_manifest(root, platform:)
        source = NARROW_DROPPED.reduce(ProductionImage.sessionless_manifest(root, platform: platform)) do |text, row|
          raise Error, "the narrow manifest finds no #{row.source[1, 30]} row" unless text.scan(row).size == 1

          text.sub(row, '')
        end
        source.gsub(/^share [a-z0-9_-]+\n(?:  .*\n)*/) { |record| narrow_share(record) }
      end

      # The network domain's rows, its net unit and its services' facets, which the narrow
      # manifest leaves out; the sessionless source has no session facet of net.
      NARROW_DROPPED = [/^runtime_limits network\n(?:  .*\n)*/, /^limits network\n(?:  .*\n)*/,
                        /^domain network\n(?:  .*\n)*/, /^unit net\n(?:  .*\n)*/, /^service net\n(?:  .*\n)*/,
                        /^service network_ctl\n(?:  .*\n)*/, /^facet network_ctl\n(?:  .*\n)*/].freeze

      # One share record of the narrow manifest: its cpuset keeps only NARROW_CPUSET's CPUs,
      # its quota_ns is capped at period_ns per remaining CPU and its capacity_mcpu at 1000
      # per remaining CPU, since the library gives a share whose quota its cpuset cannot spend
      # no rate, and plans no domain under it. A share with none of those CPUs is refused:
      # cpuset 0 would mean every CPU.
      def self.narrow_share(record)
        cpuset = share_field(record, 'cpuset') & NARROW_CPUSET
        raise Error, "the narrow manifest leaves #{record.lines.first.chomp} no CPU" if cpuset.zero?

        cpus = cpuset.to_s(2).count('1')
        record.sub(/^  cpuset \d+$/, "  cpuset #{cpuset}")
              .sub(/^  quota_ns \d+$/) { "  quota_ns #{[share_field(record, 'quota_ns'), share_field(record, 'period_ns') * cpus].min}" }
              .sub(/^  capacity_mcpu \d+$/) { "  capacity_mcpu #{[share_field(record, 'capacity_mcpu'), cpus * 1000].min}" }
      end

      # A share record's numeric field; a record without it is refused.
      def self.share_field(record, name)
        value = record[/^  #{name} (\d+)$/, 1]
        raise Error, "the narrow manifest finds no numeric #{name} in #{record.lines.first.chomp}" unless value

        Integer(value, 10)
      end
      private_class_method :share_field

      def boot_narrow(accel, count, built)
        points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern(accel), cpus: count,
                                        manifest_source: Run.narrow_manifest(@root, platform: @machine.platform),
                                        memory_mib: @machine.memory_mib)
        boot(accel, count, built, memory_mib: @machine.memory_mib, points: points, machine_end: false, command_line: COMMAND_LINES[accel])
      end

      # QEMU writes its own device tree for the suite's machine and exits; two serial ports,
      # since the second UART exists only when a second port is given.
      def check_device_paths
        directory = File.join(@root, 'build/production-image/device-tree')
        FileUtils.mkdir_p(directory)
        platform = @machine.platform
        tree = File.join(directory, "#{platform.name}.dtb")
        machine = QemuPlan.machine_line(platform, accel: 'tcg', deterministic: false)
        @runner.run([@qemu, '-machine', "#{machine},dumpdtb=#{tree}", '-cpu', 'cortex-a72', '-m', @machine.memory_mib.to_s, '-display', 'none',
                     '-serial', 'null', '-serial', 'null', '-no-reboot'], name: 'qemu-dumpdtb', deadline: 30)
        listing = @runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', tree], name: "dtc-#{platform.name}", deadline: 30)
        problems = ProductionImage.device_path_problems(platform.record, File.read(listing.fetch('log')))
        raise Error, "#{platform.record_path} disagrees with QEMU's device tree: #{problems.join('; ')}" unless problems.empty?
      end
    end

    private

    # The machine's platform, after checking it is a Machine: the default runtimes read it
    # before initialize's body runs, so the check is here and not there.
    def platform_of(machine)
      raise Error, 'an image is built for a ProductionImage::Machine' unless machine.is_a?(Machine)

      machine.platform
    end

    # A machine an image or medium is built for here, which must be on the board the
    # runtimes were linked for: a machine may add RAM or move the root, never change board.
    def on_own_board(machine)
      return if platform_of(machine) == @machine.platform

      raise Error, "a #{@machine.platform.name} image builder cannot build for #{machine.platform.name}"
    end

    def entries(root_task, kernel, sigma0)
      file = @codec.member('entry_kind', 'file')
      program = root_task.fetch(:program)
      receipt = root_task.fetch(:receipt)
      plain = { 'kind' => file, 'flags' => 0 }.freeze
      [plain.merge('path' => @codec.fixed_bytes('boot_kernel_path'), 'id' => 'kernel', 'artifact' => @fiasco.kernel_path, 'receipt' => kernel),
       plain.merge('path' => @codec.fixed_bytes('boot_sigma0_path'), 'id' => 'sigma0', 'artifact' => @fiasco.sigma0_path, 'receipt' => sigma0),
       # bootstrap loads this one, as an ELF file; the header's root entry below
       # is the same program as an image, which the manifest check sizes.
       plain.merge('path' => @codec.fixed_bytes('boot_stand_in_root_path'), 'id' => 'root-file', 'artifact' => program, 'receipt' => receipt),
       { 'path' => ROOT_ENTRY_PATH, 'kind' => @codec.member('entry_kind', 'image'), 'flags' => @codec.member('entry_flags', 'system'),
         'id' => 'root', 'artifact' => program, 'receipt' => receipt }]
    end

    # The domain boot scripts a manifest's domain rows and session templates name. Only
    # their release references are read here, so the image can carry what they name; the
    # manifest check proves the rows, each reference included, when Pack#build admits
    # the manifest.
    def domain_boots(manifest_source)
      Manifest.release_names(source: manifest_source, codec: @codec).map { |name| self.class.domain_boot(name) }
    end

    # The domain release's entries, each file once under domains/erxos/ without the
    # system mark, with a boot script for each of boots, and the two runtime images', the
    # interpreter's and the BeamAsm one (jit, NativeJitRuntime's build), with the files
    # their receipts name; nothing when there are no boot scripts. ReleaseFiles.domain
    # refuses a script it did not make, whose name could leave the work directory, and
    # two scripts of one name.
    def domain_parts(boots, erts:, jit:, archives:, facts:, directory:)
      return NOTHING_ADDED if boots.empty?

      release = ReleaseFiles.domain(boots)
      runtime = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @machine.platform,
                               fiasco: @fiasco)
                          .build_domain_runtime_receipted(directory: File.join(directory, 'domain-runtime'), archives: archives)
      domain_release = ReleaseFiles.new(root: @root, otp: erts.otp, directory: File.join(directory, 'domains'), runner: @runner,
                                        codec: @codec, release: release)
      releases = [*domain_release.entries, build_facts_entry(facts, release: release)]
      beamasm = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @machine.platform,
                               fiasco: @fiasco)
                          .build_jit_runtime_receipted(directory: File.join(directory, 'jit-runtime'),
                                                       archives: jit.link_archives(libgcc: @fiasco.user_library('libgcc.a')))
      image = { 'path' => DOMAIN_RUNTIME_PATH, 'kind' => @codec.member('entry_kind', 'image'), 'flags' => 0,
                'id' => 'domain-runtime', 'artifact' => runtime.fetch(:program), 'receipt' => runtime.fetch(:receipt) }
      jit_image = { 'path' => JIT_RUNTIME_PATH, 'kind' => @codec.member('entry_kind', 'image'), 'flags' => 0, 'jit' => true,
                    'id' => 'jit-runtime', 'artifact' => beamasm.fetch(:program), 'receipt' => beamasm.fetch(:receipt) }
      Added.new(entries: [image, jit_image, *releases, *domain_release.directories].freeze,
                inputs: [*runtime.fetch(:inputs), *beamasm.fetch(:inputs), *ReleaseFiles.inputs_of(releases, root: @root, applications: release.applications)].freeze,
                imports: {}.freeze)
    end

    # What a manifest's references name in an archive of these sorted paths: the root
    # and the two domain runtime images as executables, images as built EROFS artifacts, and
    # each domain boot script as the release's run of entries (ReleaseFiles.domain_runs). Two
    # under one name would leave a reference ambiguous, so that is refused.
    def self.artifacts(paths, images:)
      named = [{ 'root' => { 'kind' => 'executable', 'entry' => paths.index(ROOT_ENTRY_PATH) } }, images,
               ReleaseFiles.domain_runs(paths)]
      runtime = paths.index(DOMAIN_RUNTIME_PATH)
      named << { DOMAIN_RUNTIME_ARTIFACT => { 'kind' => 'executable', 'entry' => runtime } } if runtime
      beamasm = paths.index(JIT_RUNTIME_PATH)
      named << { JIT_RUNTIME_ARTIFACT => { 'kind' => 'executable', 'entry' => beamasm } } if beamasm
      names = named.flat_map(&:keys)
      raise Error, "two artifacts of the archive share a name: #{names.tally.select { |_, count| count > 1 }.keys.join(', ')}" unless
        names.uniq.size == names.size

      named.reduce(:merge)
    end

    def pack(entries:, root_task:, images:, manifest_source:, inputs:, erts:, jit:, output:, imports:, test_code:, machine:)
      tools = PackTools.build(root: @root, owner_root: @root, directory: File.join(@root, 'build/production-image-tools'),
                              runner: @runner, compiler: @compiler, sanitizers: [])
      provenance = PackProvenance.new(root: @root, catalog: catalog(root_task, inputs), external: external(erts, jit), runner: @runner,
                                      imports: imports, compiler: @compiler)
      paths = (entries.map { |entry| entry.fetch('path') } + [@codec.fixed_bytes('system_manifest_path'), NOTICES_PATH]).map(&:b).sort
      Pack.new(root: @root, output_root: @root, codec: @codec, planner: ElfPlanner.new(helper: tools.fetch('planner'), runner: @runner, codec: @codec),
               checker: tools.fetch('checker'), hasher: tools.fetch('hasher'), runner: @runner, provenance: provenance,
               domain_planner: DomainPlanner.new(helper: tools.fetch('domains'), runner: @runner))
          .build(entries: entries, root_path: ROOT_ENTRY_PATH, build_kind: BUILD_KIND, platform: machine.record,
                 artifacts: self.class.artifacts(paths, images: images),
                 manifest_source: manifest_source, output: output, test_code: test_code)
    end

    def catalog(root_task, inputs)
      fiasco = [@fiasco.kernel_path, @fiasco.sigma0_path, @fiasco.image_path, File.join(@root, 'build/fiasco/receipt.json'),
                File.join(@root, 'build/fiasco/provenance.json'), File.join(@root, 'tools/lib/erx/fiasco.rb')]
      BuildInputs.pack(root: @root, paths: [*root_task.fetch(:inputs), *inputs, *fiasco])
    end

    def build_facts_sources = BUILD_FACTS_SOURCES.map { |source| File.join(@root, source) }

    # The build-facts file (BuildFacts) and its receipt, from the facts this build
    # packs: the platform record's name and the build kind, the kernel it packs
    # (Fiasco#kernel_name, beside kernel_path), and the source revision. Its receipt
    # attributes it to the code that writes it. Each release of the image carries it
    # (build_facts_entry), so every domain reads the same facts.
    def build_facts_file(directory:, platform:)
      configuration = BuildFacts.configuration(platform: platform.name, build_kind: BUILD_KIND)
      facts = BuildFacts.gather(root: @root, runner: @runner, configuration: configuration, kernel: @fiasco.kernel_name)
      path = File.join(directory, 'build-facts')
      File.write(path, BuildFacts.render(facts))
      receipt = File.join(directory, 'build-facts.receipt.json')
      File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(path),
                                               'sources' => BUILD_FACTS_SOURCES.map { |source| reference(File.join(@root, source)) }) + "\n")
      { 'artifact' => path, 'receipt' => receipt }.freeze
    end

    # The archive entry of facts, build_facts_file's, at the ABI's build_facts_path under
    # release's root, with the system mark only in the system release, as its other files.
    def build_facts_entry(facts, release:)
      entry_path = release.prefix + @codec.fixed_bytes('build_facts_path')
      { 'path' => entry_path, 'kind' => @codec.member('entry_kind', 'file'),
        'flags' => release.system ? @codec.member('entry_flags', 'system') : 0, 'id' => entry_path, **facts }
    end

    # A receipt that says the kernel or sigma0 comes from Fiasco's audited build.
    def assembled_receipt(artifact, name:, directory:)
      receipt = { 'version' => 1, 'kind' => 'assembled', 'artifact' => reference(artifact),
                  'components' => [reference(File.join(@root, 'build/fiasco/receipt.json'))],
                  'producer' => reference(File.join(@root, 'tools/lib/erx/fiasco.rb')) }
      path = File.join(directory, "#{name}.receipt.json")
      File.write(path, JSON.pretty_generate(receipt) + "\n")
      path
    end

    # The clang that built the root, and Fiasco's archives its link takes members of.
    # jit is the BeamAsm build when the image carries its runtime image, or nil.
    def external(erts, jit)
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      ToolchainProvenance.llvm(root: @root, resource_dir: File.read(resource.fetch('log')).strip) +
        [*archives(erts), *jit_archives(jit)].map { |archive| external_archive(archive) }
    end

    def archives(erts)
      spdx = 'fiasco/l4re-core/LICENSE.spdx'
      [*otp_archives(erts.otp_archives, flavour: 'emu'),
       Archive.new(path: erts.libc, label: 'musl libc', license: 'MIT', status: 'permanent', notices: ['musl/COPYRIGHT']),
       Archive.new(path: @fiasco.user_library('libgcc.a'), label: 'fiasco/l4re-core libgcc',
                   license: 'GPL-3.0-only WITH GCC-exception-3.1', status: 'stopgap', notices: [spdx]),
       Archive.new(path: @fiasco.user_library('libl4sys.p.a'), label: 'fiasco/l4re-core libl4sys',
                   license: 'MIT', status: 'stopgap', notices: [spdx]),
       Archive.new(path: @fiasco.user_library('libsigma0.a'), label: 'fiasco/l4re-core libsigma0',
                   license: 'MIT', status: 'stopgap', notices: [spdx]),
       Archive.new(path: @fiasco.boot_core_archive, label: 'kernel/core boot cores',
                   license: 'BSD-2-Clause', status: 'permanent', notices: [LICENSE])]
    end

    # The BeamAsm build's own archives: ERTS's BeamAsm flavour, asmjit's Zlib licence
    # within libbeam.a's whole, and the C++ runtime. musl's libc.a is the interpreter's.
    def jit_archives(jit)
      return [] unless jit

      tree = Dependencies.new(root: @root, runner: @runner).fetched_tree(Libcxx::SOURCE_ID).delete_prefix("#{@root}/")
      [*otp_archives(jit.otp_archives, flavour: 'jit'),
       *jit.cxx_archives.map do |path|
         name = File.basename(path)
         Archive.new(path: path, label: "llvm #{name}", license: 'Apache-2.0 WITH LLVM-exception',
                     status: 'permanent', notices: [File.join(tree, LIBCXX_NOTICES.fetch(name))])
       end]
    end

    def otp_archives(paths, flavour:)
      paths.map do |path|
        name = File.basename(path)
        license, notices = if name == EMULATOR_ARCHIVE
                             emulator_license(flavour)
                           else
                             ['Apache-2.0', ['otp/LICENSE.txt']]
                           end
        Archive.new(path: path, label: "otp #{flavour} #{name}", license: license, status: 'permanent', notices: notices)
      end
    end

    # libbeam.a holds littlefs's objects, and in the BeamAsm flavour asmjit's too.
    def emulator_license(flavour)
      return ['Apache-2.0 AND BSD-3-Clause', ['otp/LICENSE.txt', 'littlefs/LICENSE.md']] unless flavour == 'jit'

      ['Apache-2.0 AND BSD-3-Clause AND Zlib', ['otp/LICENSE.txt', 'littlefs/LICENSE.md', 'otp/erts/emulator/asmjit/LICENSE.md']]
    end

    def external_archive(archive)
      reference(archive.path).merge('path' => File.realpath(archive.path), 'label' => archive.label, 'license' => archive.license,
                                    'evidence' => 'archive built by the tree\'s own build, attributed as a whole',
                                    'status' => archive.status,
                                    'notices' => archive.notices.map { |notice| reference(File.join(@root, notice)) })
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    def digests(built, medium)
      { 'archive_sha256' => built.archive, 'single_sha256' => built.single,
        'release_erofs_sha256' => built.erofs, 'medium_sha256' => medium.path }
        .transform_values { |path| Digest::SHA256.file(path).hexdigest }
    end

    # The directory a build packed into, as OutputDirectory.prepare resolved it: the real
    # path, which may differ from the spelling its caller passed.
    def built_directory(built) = File.dirname(built.archive)
  end
end
