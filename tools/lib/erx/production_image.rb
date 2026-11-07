# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'abi'
require_relative 'boot_file'
require_relative 'build_inputs'
require_relative 'crash_frame'
require_relative 'deterministic_transcript'
require_relative 'error'
require_relative 'fiasco'
require_relative 'fiasco_provenance'
require_relative 'files_guest'
require_relative 'hostlink_guest'
require_relative 'reload_guest'
require_relative 'code_watch'
require_relative 'json_input'
require_relative 'manifest'
require_relative 'native_root'
require_relative 'native_runtime'
require_relative 'output_directory'
require_relative 'pack'
require_relative 'pack_provenance'
require_relative 'pack_tools'
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
    PLATFORM = 'config/platforms/qemu-virt.json'
    MANIFEST = 'config/manifest/qemu-virt-development.txt'
    ROOT_ENTRY_PATH = 'system/root'
    NOTICES_PATH = 'system/NOTICES'
    MEMORY_MIB = 160
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
    # generator's stream, and OTP for the release's beams.
    IMPORTS = { 'kernel/crypto/blake3' => 'permanent', 'kernel/crypto/chacha20' => 'permanent', 'otp' => 'permanent' }.freeze

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

    # The QEMU virt machine an image boots on: its RAM, the part of it Fiasco keeps
    # (fiasco_reserve, which grows with RAM, since Fiasco sizes its kernel memory as
    # 6% of it), system_growth_mib, which is added to both root_memory and
    # system_baseline of the development manifest, and tmp_growth_mib, which is added
    # to /tmp's cap and is part of the system growth, since /tmp lives in the baseline,
    # and root_mib, the root task's place in MiB from the start of RAM (root_address),
    # which the root's link takes (liberx/backend/fiasco/root.ld). The root is a fixed
    # image, so each machine names its place: low on a small machine, whose RAM must
    # hold the root, and higher where a test image's archive, which lies below the
    # root, is larger.
    # What the system growth leaves of the added RAM widens the room bootstrap keeps
    # for the archive. The production image boots on DEVELOPMENT_MACHINE, the
    # platform record's own; a test image whose suites need more memory or carry a
    # larger archive (OracleQemu) names a larger one, and Pack's manifest check proves
    # the grown manifest against the platform record of that machine as it proves the
    # development one.
    Machine = Data.define(:memory_mib, :fiasco_reserve_mib, :system_growth_mib, :tmp_growth_mib, :root_mib) do
      # The root's place, with room for the root's image (about 5 MiB) before RAM ends.
      def root_address
        raise Error, "the root's place, #{root_mib} MiB into RAM, leaves no room for it in #{memory_mib} MiB" if
          root_mib.negative? || root_mib + ROOT_ROOM_MIB > memory_mib

        NativeRoot::RAM_FIRST + (root_mib << 20)
      end

      def platform(record) = record.merge('ram_bytes' => memory_mib << 20, 'fiasco_reserve' => fiasco_reserve_mib << 20)

      # The development manifest's text with root_memory and system_baseline each grown
      # by system_growth_mib and /tmp's cap by tmp_growth_mib; any other line is unchanged.
      def manifest(source)
        raise Error, "/tmp's growth is more than the system's" if tmp_growth_mib > system_growth_mib

        { 'root_memory' => system_growth_mib, 'system_baseline' => system_growth_mib, 'tmp' => tmp_growth_mib }
          .reduce(source) do |text, (field, growth_mib)|
            pattern = /^(  #{field} )([0-9]+)$/
            raise Error, "the manifest does not have exactly one #{field} line" unless text.scan(pattern).size == 1

            text.sub(pattern) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2), 10) + (growth_mib << 20)}" }
          end
      end
    end
    DEVELOPMENT_MACHINE = Machine.new(memory_mib: MEMORY_MIB, fiasco_reserve_mib: 16, system_growth_mib: 0, tmp_growth_mib: 0,
                                      root_mib: 64)

    def initialize(root:, runner:, compiler:, linker:, fiasco: Fiasco.new(root: root, runner: runner, compiler: compiler),
                   runtime: NativeRuntime.new(root: root, runner: runner, compiler: compiler, linker: linker, fiasco: fiasco))
      @root = File.realpath(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @fiasco = fiasco
      @runtime = runtime
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
    def build(directory:, manifest_source: File.binread(File.join(@root, MANIFEST)))
      assemble(directory: directory, manifest_source: manifest_source, added: NOTHING_ADDED, test_code: false,
               machine: DEVELOPMENT_MACHINE)
    end

    # The image and the release medium for QEMU that holds it (ReleaseMedium), both in
    # directory, which must be clean.
    def build_medium(directory:)
      built = build(directory: directory)
      [built, ReleaseMedium.write(built: built, directory: built_directory(built))]
    end

    # The production image with test code added to its system release, marked in its
    # archive's flags (ERX_PACK_TEST_CODE) so the kernel's banner says so and the kernel
    # refuses it in any build but a development one. Only the QEMU harnesses that boot
    # test code, OracleQemu and BlockDevice, call it, which the source check holds
    # (Checks::TEST_IMAGE_BUILDERS).
    def build_test_image(directory:, added:, machine: DEVELOPMENT_MACHINE)
      raise Error, 'a test image adds test code' unless added.is_a?(Added) && !added.entries.empty?

      assemble(directory: directory, manifest_source: machine.manifest(File.binread(File.join(@root, MANIFEST))), added: added,
               test_code: true, machine: machine)
    end

    # Both entry points' one build: the system release, any additions, and the mark that
    # says whether there are some.
    def assemble(directory:, manifest_source:, added:, test_code:, machine:)
      directory = OutputDirectory.prepare(root: @root, path: directory)
      raise Error, 'a production image builds into a clean directory' unless Dir.empty?(directory)

      sources = Runtime.source_digest(root: @root)
      erts = @runtime.build
      archives = [*erts.otp_archives, erts.libc, @fiasco.user_library('libgcc.a')]
      root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: @fiasco)
                            .build_system_receipted(directory: File.join(directory, 'root'), archives: archives,
                                                    place: machine.root_address)
      kernel = assembled_receipt(@fiasco.kernel_path, name: 'kernel', directory: directory)
      sigma0 = assembled_receipt(@fiasco.sigma0_path, name: 'sigma0', directory: directory)
      archive = File.join(directory, 'image.erxpack')
      File.write(self.class.sources_path(archive), sources)
      release = ReleaseFiles.new(root: @root, otp: erts.otp, directory: File.join(directory, 'release'), runner: @runner, codec: @codec).entries
      erofs, images = ReleaseMedium.image(entries: release, directory: directory, runner: @runner)
      report = pack(entries: [*entries(root_task, kernel, sigma0), *release, *added.entries], root_task: root_task, images: images,
                    manifest_source: manifest_source, erts: erts, output: archive, imports: IMPORTS.merge(added.imports),
                    inputs: [kernel, sigma0, *ReleaseFiles.inputs_of(release, root: @root), *added.inputs], test_code: test_code,
                    machine: machine)
      single = File.join(directory, 'image.boot')
      BootFile.write(codec: @codec, first_stage: @fiasco.image_path, archive: archive, output: single, output_root: @root)
      header = @codec.decode_layout('erx_pack_header', File.binread(archive, @codec.layout_size('erx_pack_header')))
      flags = header.fetch('flags')
      marked = flags.anybits?(@codec.member('pack_flags', 'test_code'))
      raise Error, 'the archive header disagrees with the test-code mark asked for' unless marked == test_code

      Built.new(single: single, archive: archive, first_stage: @fiasco.image_path,
                index_hash: header.fetch('index_hash').unpack1('H*'), build_id: header.fetch('build_id').unpack1('H*'),
                flags: flags, test_code: marked, report: report, release: release, erofs: erofs)
    end
    private :assemble

    # The same inputs give byte-identical images: two whole builds of the runtime, each
    # packed into a clean directory of its own name with its release medium, compared
    # part by part by SHA-256, read as a stream. A path under those directories that
    # reached an output shows; OTP and musl build at one path both times, so a path of
    # theirs does not. Fiasco's own assembly has its own test
    # (test/integration/fiasco_reproducible_test.rb); both builds here pack its one result.
    def check_reproducible(directory:)
      directory = OutputDirectory.prepare(root: @root, path: directory)
      raise Error, 'a reproducibility check needs a clean directory' unless Dir.empty?(directory)

      (first, first_medium), (second, second_medium) = %w[first second].map do |name|
        @runtime.clean
        build_medium(directory: File.join(directory, name))
      end
      first_digests = digests(first, first_medium)
      second_digests = digests(second, second_medium)
      differing = first_digests.keys.reject { |part| first_digests.fetch(part) == second_digests.fetch(part) }
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

    # The problems of a platform record against a device tree as dtc prints it: a path the
    # tree lacks, a node whose compatible list does not name what the record says, or a
    # window or line other than the node's.
    def self.device_path_problems(platform, dts)
      nodes = dts.scan(/^\t([^\s{}]+) \{\n(.*?)^\t\};/m).to_h do |name, body|
        ["/#{name}", { compatible: body[/^\t\tcompatible = (.*?);/, 1].to_s.scan(/"([^"]+)"/).flatten,
                       window: node_window(body) }]
      end
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
        end
      end
    end

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
      # The system share's cpuset in the narrow image: CPUs 0 and 1.
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
      ERLANG_SHELL = { name: 'erlang-shell', pattern: /\AEshell V/n, seconds: 60 }.freeze
      # kernel_sup's children at a boot with no carrier, in which_children's order: the last
      # started first (docs/design-runtime.md, Configuration).
      KERNEL_CHILDREN = %w[kernel_safe_sup kernel_refc kernel_config logger_sup user erl_signal_server
                           global_group global_name_server rex inet_db erx_watchdog on_load
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
      # The program's name and the node flag with its name, before the page's words, and
      # the five words of -erx console_uart, the four of -erx boot VALUE SLOT and the three of
      # -erx build ID, which the root adds to the manifest's.
      ARGUMENTS_ALWAYS = 15
      # The words of -erx device ROLE PERIPHERAL BASE SIZE LINE DMA_MEMORY, which the root adds
      # for the block unit's one device and the host link's UART (docs/design-stopgap.md,
      # "Device records").
      DEVICE_RECORD_WORDS = 8
      # What a plain erx.arg word used to break: it joins the last flag's arguments.
      CONSOLE_PLAIN_WORD = 'erx.arg=plainword'
      # An output longer than any FIFO, so the driver writes it through the transmit check.
      CONSOLE_LONG_BYTES = 20_000
      # A tab and an escape sequence in a debug log record, typed as byte values.
      LOG_AFTER_HANDOFF = %(erx_log:debug(<<"after",9,"handoff",27,"[1m">>).\r)
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
      KERNEL_RECORD_ANSWERS = { 'machine' => /\A(?:[0-9]+> )?#\{/n, 'cpus' => /\A(?:[0-9]+> )?\{(?:ok|partial),\[/n,
                                'group' => /\A(?:[0-9]+> )?#\{/n, 'budget' => /\A(?:[0-9]+> )?#\{/n,
                                'threads' => /\A(?:[0-9]+> )?\{(?:ok|partial),\[/n }.freeze
      # The five records again, each without its {kernel,unsupported} attributes, so what is
      # left is what the stopgap reports: for a listing its status, its length and the
      # attributes any of its records reports.
      KERNEL_RECORD_SUMMARY = 'U=fun(R)->lists:sort([{K,V}||K:=V<-maps:get(attrs,R),V=/={kernel,unsupported}]) end,' \
                              'L=fun({S,Rs})->{S,length(Rs),lists:usort(lists:append([U(R)||R<-Rs]))} end,' \
                              'M=erx_kernel_records,io:format("~w~n",[{object_info,U(M:machine()),L(M:cpus()),' \
                              "U(M:group()),U(M:budget()),L(M:threads())}]).\r"

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
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
        narrow = cpus.max > 1 ? image(fiasco, directory: 'build/production-image/narrow', manifest_source: narrow_manifest) : nil
        full_matrix(accels, cpus, built, narrow).merge(smoke ? smoke_cells(built) : {})
      end

      # The transcript of a boot as far as ERTS gets, each line in order. The image is one
      # without test code, and the kernel's line names its archive's identity and flags,
      # so a test image's mark shows. The manifest line
      # carries the numbers the source says, so a root that misread it fails. Schedulers are
      # one per CPU of the system's share on this machine. Erlang's init then boots the
      # release, `kernel` starts, and erx_console's slogan and its command shell's banner,
      # written through erx_pl011, prove the release ran that far. The command shell's
      # prompt ends no line, so no point names it.
      def self.checkpoints(built, root:, watchdog:, cpus:, extra_arguments: 0, manifest_source: File.read(File.join(root, MANIFEST)))
        source = manifest_source
        memory, baseline = %w[root_memory system_baseline].map { |key| source[/^\s*#{key} (\d+)$/, 1] }
        units = source.scan(/^unit /).size
        records = source.scan(/^unit (?:block|hostlink)$/).size * DEVICE_RECORD_WORDS
        arguments = ARGUMENTS_ALWAYS + records + source[/^\s*system_args "(.*)"$/, 1].split.size + extra_arguments
        count = schedulers(source, cpus: cpus)
        raise Error, 'a production boot refuses a test image' if built.test_code

        image = /\Aerx: boot image build #{built.build_id} index #{built.index_hash} flags 0x#{built.flags.to_s(16)} archive /n
        identity = /\Aerx: root task: build #{built.build_id} index #{built.index_hash} entries [0-9]+\r?\n\z/n
        manifest = /\Aerx: root task: manifest root_memory #{memory} baseline #{baseline} units #{units} pool pages [0-9]+\r?\n\z/n
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
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
      def self.idle_checkpoints(cpus:, root:)
        # Each scheduler and each dirty CPU scheduler holds an executor slot.
        executors = 2 * schedulers(File.read(File.join(root, MANIFEST)), cpus: cpus)
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
         { name: 'release-slogan', pattern: %r{Erlang/OTP 29 }n, seconds: 240 }.freeze,
         { name: 'release-shell', pattern: /#{Regexp.escape(COMMAND_SHELL_BANNER)}/n, seconds: 60, type: ERL_LINE }.freeze,
         { name: 'erlang-shell', pattern: /Eshell V/n, seconds: 60, type: BUSY_EXPRESSION }.freeze,
         # The report's bytes may fall inside the driver's, so the line is looked for at its end only.
         { name: 'idle-parked', pattern: /erx: root task: group: parked #{executors} of #{executors}\r*\n\z/n,
           seconds: EVAL_SECONDS }.freeze].freeze
      end

      # The kernel-object records at the Erlang shell, at the statuses design-stopgap.md's
      # "Reporting kernel objects" table gives. Of the attributes only the kernel could
      # report, just these are ok: the machine's cpus_online and the system group's parked
      # and ready. The group's cpuset would be ok once a set is configured, and nothing
      # configures the system group's. The budget's used is partial, with reporter
      # liberx_pool, and above zero. Every other attribute is unsupported with reporter
      # kernel, and the CPUs and the system domain's threads are listed whole. Each answer
      # types the next collector, the last types the summary, and the summary's line must
      # be exactly that.
      def self.kernel_record_checkpoints(cpus:)
        typed = [*KERNEL_RECORD_ANSWERS.keys.map { |call| %(io:format("~w~n",[erx_kernel_records:#{call}()]).\r) },
                 KERNEL_RECORD_SUMMARY]
        answers = KERNEL_RECORD_ANSWERS.zip(typed.drop(1)).map do |(call, start), type|
          { name: "kernel-record-#{call}", pattern: start, seconds: EVAL_SECONDS, type: type }.freeze
        end
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), SLOGAN,
         RELEASE_SHELL.merge(type: ERL_LINE).freeze, ERLANG_SHELL.merge(type: typed.first).freeze, *answers,
         { name: 'kernel-record-summary', pattern: /\A(?:[0-9]+> )?\{object_info,/n, seconds: EVAL_SECONDS,
           verify: whole_line(kernel_record_line(cpus: cpus), speaker: 'the kernel records read') }.freeze].freeze
      end

      # The summary line KERNEL_RECORD_SUMMARY writes on a machine of cpus CPUs: the fixed
      # text escaped, with a pattern only where a number may vary.
      def self.kernel_record_line(cpus:)
        any_number = '[0-9]+'
        positive = '[1-9][0-9]*'
        text = ->(fixed) { Regexp.escape(fixed) }
        ok = ->(key, value) { "#{text.call("{#{key},{kernel,{ok,")}#{value}#{text.call('}}}')}" }
        machine = text.call('[') + ok.call('cpus_online', cpus) + text.call(']')
        cpu_listing = text.call("{ok,#{cpus},[]}")
        group = text.call('[') + ok.call('parked', any_number) + ',' + ok.call('ready', any_number) + text.call(']')
        budget = text.call('[{used,{{stopgap,liberx_pool},{partial,') + positive + text.call('}}}]')
        threads = text.call('{ok,') + positive + text.call(',[]}')
        summary = text.call('{object_info,') + [machine, cpu_listing, group, budget, threads].join(',') + text.call('}')
        /\A(?:[0-9]+> )?#{summary}\r*\n\z/n
      end
      private_class_method :kernel_record_line

      # A person at the serial console. The first line, erl, is typed at the boot's development
      # warning, before the driver starts, so the FIFO holds it when the driver takes the UART,
      # and the command shell reads it at its first prompt and starts the Erlang shell. At the
      # Erlang shell's banner the person types a sum, and each answer then types the next
      # line: a line with a mistake rubbed out, under which the sum is 4 where the mistake is
      # a syntax error, an output longer than any FIFO, a debug log record, what
      # erlang:processes() lists, and a module compiled and a tracer started with compiler
      # and runtime_tools loaded and neither started, and an rc line the command shell's
      # evaluator runs with its Erlang commands.
      def self.console_checkpoints
        boot = Qemu.boot_transcript(memory_mib: MEMORY_MIB).map do |point|
          point.fetch(:name) == 'development-warning' ? point.merge(type: ERL_LINE).freeze : point
        end
        raise Error, 'the boot transcript has no development warning to type at' unless boot.any? { |point| point.key?(:type) }

        [*boot, SLOGAN,
         console_point('release-shell', RELEASE_SHELL.fetch(:pattern)),
         console_point('shell', ERLANG_SHELL.fetch(:pattern), type: "1+1.\r"),
         console_point('sum-echo', /1\+1\.\r*\n\z/n),
         console_point('sum-answer', /\A2\r*\n\z/n, type: "1+2\x7f3.\r"),
         console_point('edit-answer', /\A4\r*\n\z/n, type: "io:put_chars(lists:duplicate(#{CONSOLE_LONG_BYTES},$x)),io:nl().\r"),
         console_point('long-output', /x{#{CONSOLE_LONG_BYTES}}/n),
         console_point('long-answer', /\Aok\r*\n\z/n, type: LOG_AFTER_HANDOFF),
         # A record logged once the driver owns the UART: the console reads it and writes it
         # escaped, tab and escape byte as text, never as the bytes themselves.
         console_point('log-after-handoff', /\A(?:[0-9]+> )?#[0-9]+ [0-9]+\.[0-9]+ [a-z]+ .*after\\x09handoff\\x1B\[1m\r*\n\z/n,
                       type: PROCESSES_EXPRESSION),
         # The echo of the line reads {processes,length, so only the answer matches.
         console_point('processes', /\A(?:[0-9]+> )?\{processes,[0-9]/n,
                       whole: /\A(?:[0-9]+> )?\{processes,[1-9][0-9]*,\[\],emu\}\r*\n\z/n, type: LOAD_ONLY_EXPRESSION),
         # The echo of the line starts {ok,M,B}=, so only the answer matches.
         console_point('load-only', /\A(?:[0-9]+> )?\{load_only,/n,
                       whole: /\A(?:[0-9]+> )?\{load_only,\[false,false\],\[true,true\],compiled,ok,ok\}\r*\n\z/n,
                       type: RC_EXPRESSION),
         # The echo of the line holds `echo rc:`, so only the output starts with rc:.
         console_point('rc-output', /\A(?:[0-9]+> )?rc: /n, whole: /\A(?:[0-9]+> )?rc: 2 hello world f \|\r*\n\z/n),
         console_point('rc-ending', /\A(?:[0-9]+> )?\{ok,<<>>\}\r*\n\z/n)].freeze
      end

      # A line of the console's transcript, what the person types once it is seen, and the
      # whole line it must be, whose mismatch raises with the line.
      def self.console_point(name, pattern, type: nil, whole: nil)
        verify = whole && whole_line(whole, speaker: 'the console answered')
        { name: name, pattern: pattern, seconds: EVAL_SECONDS, **{ type: type, verify: verify }.compact }.freeze
      end
      private_class_method :console_point

      # The release's boot with its children named, then the line that outlived the deadlines.
      # init's -eval writes beside the command shell, so a line of its may follow the unended prompt.
      def self.survival_checkpoints(seconds:)
        children = KERNEL_CHILDREN.join(',')
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
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
      def self.command_line_refusal_checkpoints
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
         { name: 'root-refusal', pattern: /\Aerx: root task refused the boot: the kernel command line/n, seconds: 30 }.freeze].freeze
      end

      # A device tree that names the console's UART by another path than the manifest's
      # console, through an alias and with options after it: the root says both paths
      # and ends the machine.
      def self.stdout_path_refusal_checkpoints
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
         { name: 'root-refusal', seconds: 30,
           pattern: %r{\Aerx: root task refused the boot: manifest: the console /pl011@9000000 is not the node /chosen/stdout-path names, #{Regexp.escape(SEEDED_STDOUT_NODE)}\r?\n}n }.freeze].freeze
      end

      def self.point(name, pattern, whole, seconds: 30, speaker: 'the root task reports')
        { name: name, pattern: pattern, seconds: seconds, verify: whole_line(whole, speaker: speaker) }.freeze
      end
      private_class_method :point

      # A checkpoint's verifier: the line it selected must match whole, or it raises with the line.
      def self.whole_line(whole, speaker:)
        ->(text) { raise Error, "#{speaker} #{text.inspect}" unless whole.match?(text) }
      end
      private_class_method :whole_line

      private

      # SMOKE_CELLS under TCG: the plain boot to the command shell at one CPU, then the transcript.
      # Each name sits beside the boot that earns it, so dropping a boot drops its cell, and
      # the gate then marks the declared cell not_run.
      def smoke_cells(built)
        { 'tcg-1cpu' => smoke_boot(built), 'tcg-deterministic' => deterministic(built) }
      end

      def smoke_boot(built)
        points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern('tcg'), cpus: 1)
        full = boot('tcg', 1, built, memory_mib: MEMORY_MIB, points: points, machine_end: false, command_line: COMMAND_LINES['tcg'])
        { serial: full.fetch('serial_log'), seconds: full.fetch('elapsed_seconds') }.freeze
      end

      # The watchdog numbers the boot reports: TCG's from COMMAND_LINES, and under HVF the
      # kernel's defaults, whatever they are.
      def watchdog_pattern(accel) = accel == 'tcg' ? TCG_WATCHDOG : '[0-9]+,[0-9]+,[0-9]+'

      def full_matrix(accels, cpus, built, narrow)
        accels.product(cpus).to_h do |accel, count|
          points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern(accel), cpus: count)
          full = boot(accel, count, built, memory_mib: MEMORY_MIB, points: points, machine_end: false, command_line: COMMAND_LINES[accel])
          if count == cpus.first
            boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: true, command_line: UNKNOWN_WORD_LINE,
                                      points: Run.command_line_refusal_checkpoints)
            boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: true, dtb: seeded_stdout_tree(accel, count, built),
                                      points: Run.stdout_path_refusal_checkpoints)
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
        points = Run.checkpoints(built, root: @root, watchdog: 'off', cpus: 1, extra_arguments: DETERMINISTIC_LINE.scan('erx.arg=').size)
        first, second = Array.new(2) do
          report = boot('tcg', 1, built, memory_mib: MEMORY_MIB, machine_end: false, command_line: DETERMINISTIC_LINE, points: points)
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
        boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: false, points: Run.survival_checkpoints(seconds: seconds),
                                  command_line: "#{line} erx.arg=#{expression}")
        window = proof.fetch(:pet) + proof.fetch(:period) + PET_MARGIN_SECONDS
        stopped = boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: true, command_line: "#{line} erx.arg=#{STOP_PET}",
                                            points: [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), SLOGAN,
                                                     { name: 'pet-stopped', pattern: /\A(?:% )?pet_stopped\r*\n\z/n, seconds: EVAL_SECONDS }.freeze,
                                                     { name: 'watchdog-fired', pattern: /#{Regexp.escape(CrashFrame::BEGIN_MARKER)}/n, seconds: window }.freeze])
        judge_missed_pet(File.binread(stopped.fetch('serial_log')))
        judge_missed_pet_time(stopped.fetch('checkpoints'), proof)
      end

      # An rc line that the command shell runs with its Erlang commands, in a directory of
      # its own under /tmp: redirections to a file, a pipeline, substitutions, ls and ps.
      # Its one line of output names the line count, the file's words, ls's one name and
      # the statuses of `ps | cat`, then the Erlang shell prints how the source ended.
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
        points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern(accel), cpus: count)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB, checkpoints: points, machine_end: false,
                 command_line: COMMAND_LINES[accel], directory: hostlink_directory(accel),
                 link: ->(socket) { HostlinkGuest.call(socket, build: built.build_id) }, link_seconds: HostlinkGuest::SECONDS)
      end

      # M4's files check (FilesGuest): the guest boots writing a file into /tmp with tmp
      # among its host link's files trees, and the host reads it through tools/erx files.
      def files_boot(accel, count, built)
        line = [COMMAND_LINES[accel], FilesGuest.command_line].compact.join(' ')
        points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern(accel), cpus: count,
                                        extra_arguments: FilesGuest::ARGUMENTS.size)
        directory = File.join(@root, 'build/qemu', "fl-#{accel}-#{Process.pid}")
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB, checkpoints: points, machine_end: false,
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
        points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern(accel), cpus: count, extra_arguments: 2)
        directory = File.join(@root, 'build/qemu', "rl-#{accel}-#{Process.pid}")
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB, checkpoints: points, machine_end: false,
                 command_line: line, directory: directory, link_seconds: ReloadGuest::SECONDS,
                 link: lambda { |socket|
                   ReloadGuest.call(socket, build: built.build_id, modules: modules,
                                            serial: File.join(File.dirname(socket), 'serial.log'), cpus: count)
                 })
      end

      # A run directory whose socket path fits a UNIX socket's (QemuPlan::SOCKET_PATH_MAX).
      def hostlink_directory(accel) = File.join(@root, 'build/qemu', "hl-#{accel}-#{Process.pid}")

      def console_boot(accel, count, built)
        boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: false, points: Run.console_checkpoints,
                                  command_line: [COMMAND_LINES[accel], CONSOLE_PLAIN_WORD].compact.join(' '))
      end

      # A record the console has not read when the root stops itself: the end path writes it to
      # the line before the machine ends, so suspending the console first loses nothing. The
      # text is "parked", tab, "at", tab, "end", as code points, since the line holds no quote.
      def parked_log_boot(accel, count, built)
        expression = 'erlang:suspend_process(whereis(erx_console)),' \
                     'erx_log:debug([112,97,114,107,101,100,9,97,116,9,101,110,100]),erlang:halt().'
        boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: true,
                                  command_line: [COMMAND_LINES[accel], "erx.arg=-eval erx.arg=#{expression}"].compact.join(' '),
                                  points: [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), SLOGAN,
                                           { name: 'parked-at-end', pattern: /debug .*parked\\x09at\\x09end\r*\n\z/n,
                                             seconds: EVAL_SECONDS }.freeze])
      end

      def idle_boot(accel, count, built)
        boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: false, points: Run.idle_checkpoints(cpus: count, root: @root),
                                  command_line: [COMMAND_LINES[accel], GROUP_REPORT_WORD].compact.join(' '))
      end

      # The kernel-object records, read at the Erlang shell (Run.kernel_record_checkpoints).
      def kernel_records_boot(accel, count, built)
        boot(accel, count, built, memory_mib: MEMORY_MIB, machine_end: false, points: Run.kernel_record_checkpoints(cpus: count),
                                  command_line: COMMAND_LINES[accel])
      end

      def judge_missed_pet(serial)
        result = CrashFrame.read(serial)
        raise Error, CrashFrame.report(result).join(' / ') unless result.status == :valid

        cause = result.record.fetch('cause')
        raise Error, "a stopped pet ended the machine with cause #{cause}" unless cause == CrashFrame::CODEC.member('crash_cause', 'watchdog')
      end

      def boot(accel, count, built, memory_mib:, points:, machine_end:, command_line: nil, dtb: nil)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, image: built.single, memory_mib: memory_mib, checkpoints: points, machine_end: machine_end,
                 command_line: command_line, dtb: dtb)
      end

      # The seeded tree's name for the console's PL011, which its stdout-path names through
      # the alias SEEDED_STDOUT_ALIAS.
      SEEDED_STDOUT_NODE = '/uart@9000000'
      SEEDED_STDOUT_ALIAS = 'serial0'

      # QEMU's own tree for the machine a boot gets, with the console's node renamed
      # (seed_stdout_path). -dtb hands a boot this tree in place of the one QEMU would write.
      def seeded_stdout_tree(accel, count, built)
        directory = File.join(@root, 'build/production-image/device-tree')
        FileUtils.mkdir_p(directory)
        stock = File.join(directory, "#{accel}-#{count}cpu.dtb")
        seeded = File.join(directory, "#{accel}-#{count}cpu-stdout.dtb")
        argv = QemuPlan.argv(accel: accel, image: File.expand_path(built.single), serial: '/dev/null', cpus: count, memory_mib: MEMORY_MIB, program: @qemu)
        machine = argv.index('-machine') + 1
        @runner.run([*argv[0...machine], "#{argv[machine]},dumpdtb=#{stock}", *argv[(machine + 1)..]], name: 'qemu-dumpdtb-seed', deadline: 30)
        listing = File.read(@runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', stock], name: 'dtc-seed', deadline: 30).fetch('log'))
        source = File.join(directory, "#{accel}-#{count}cpu-stdout.dts")
        File.write(source, ProductionImage.seed_stdout_path(listing, node: '/pl011@9000000', renamed: SEEDED_STDOUT_NODE,
                                                                    alias_name: SEEDED_STDOUT_ALIAS))
        @runner.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', seeded, source], name: 'dtc-seeded', deadline: 30)
        seeded
      end

      def image(fiasco, directory: 'build/production-image/boot', manifest_source: nil)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, directory))
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                       .build(directory: directory, **{ manifest_source: manifest_source }.compact)
      end

      # The manifest with the system share on the machine's first two CPUs only. A boot of it
      # on a larger machine tells a scheduler count taken from the share and the online CPUs
      # together from one taken from the online CPUs alone, which the manifest's own cpuset,
      # every CPU the runs have, cannot.
      def narrow_manifest
        File.read(File.join(@root, MANIFEST)).sub(/^(share system\n(?:  .*\n)*?  cpuset )\d+$/) { "#{Regexp.last_match(1)}#{NARROW_CPUSET}" }
      end

      def boot_narrow(accel, count, built)
        points = Run.checkpoints(built, root: @root, watchdog: watchdog_pattern(accel), cpus: count,
                                        manifest_source: narrow_manifest)
        boot(accel, count, built, memory_mib: MEMORY_MIB, points: points, machine_end: false, command_line: COMMAND_LINES[accel])
      end

      # QEMU writes its own device tree and exits; two serial ports, since the second
      # UART exists only when a second port is given.
      def check_device_paths
        directory = File.join(@root, 'build/production-image/device-tree')
        FileUtils.mkdir_p(directory)
        tree = File.join(directory, 'virt.dtb')
        @runner.run([@qemu, '-machine', "virt,dumpdtb=#{tree}", '-cpu', 'cortex-a72', '-m', MEMORY_MIB.to_s, '-display', 'none',
                     '-serial', 'null', '-serial', 'null', '-no-reboot'], name: 'qemu-dumpdtb', deadline: 30)
        listing = @runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', tree], name: 'dtc-virt', deadline: 30)
        platform = JsonInput.parse(File.binread(File.join(@root, PLATFORM)), max_bytes: 65_536, label: 'platform record')
        problems = ProductionImage.device_path_problems(platform, File.read(listing.fetch('log')))
        raise Error, "#{PLATFORM} disagrees with QEMU's device tree: #{problems.join('; ')}" unless problems.empty?
      end
    end

    private

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

    def pack(entries:, root_task:, images:, manifest_source:, inputs:, erts:, output:, imports:, test_code:, machine:)
      tools = PackTools.build(root: @root, owner_root: @root, directory: File.join(@root, 'build/production-image-tools'),
                              runner: @runner, compiler: @compiler, sanitizers: [])
      provenance = PackProvenance.new(root: @root, catalog: catalog(root_task, inputs), external: external(erts), runner: @runner,
                                      imports: imports, compiler: @compiler)
      paths = (entries.map { |entry| entry.fetch('path') } + [@codec.fixed_bytes('system_manifest_path'), NOTICES_PATH]).map(&:b).sort
      platform = machine.platform(JsonInput.parse(File.binread(File.join(@root, PLATFORM)), max_bytes: 65_536, label: 'platform record'))
      Pack.new(root: @root, output_root: @root, codec: @codec, planner: ElfPlanner.new(helper: tools.fetch('planner'), runner: @runner, codec: @codec),
               checker: tools.fetch('checker'), hasher: tools.fetch('hasher'), runner: @runner, provenance: provenance)
          .build(entries: entries, root_path: ROOT_ENTRY_PATH, build_kind: 'development', platform: platform,
                 artifacts: { 'root' => { 'kind' => 'executable', 'entry' => paths.index(ROOT_ENTRY_PATH) } }.merge(images),
                 manifest_source: manifest_source, output: output, test_code: test_code)
    end

    def catalog(root_task, inputs)
      fiasco = [@fiasco.kernel_path, @fiasco.sigma0_path, @fiasco.image_path, File.join(@root, 'build/fiasco/receipt.json'),
                File.join(@root, 'build/fiasco/provenance.json'), File.join(@root, 'tools/lib/erx/fiasco.rb')]
      BuildInputs.pack(root: @root, paths: [*root_task.fetch(:inputs), *inputs, *fiasco])
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
    def external(erts)
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      installation = File.expand_path('../../..', File.read(resource.fetch('log')).strip)
      ToolchainProvenance.registry(profile: File.join(@root, 'config/provenance/llvm-23.1.3.json'), installation: installation) +
        archives(erts).map { |archive| external_archive(archive) }
    end

    def archives(erts)
      spdx = 'fiasco/l4re-core/LICENSE.spdx'
      otp = erts.otp_archives.map do |path|
        name = File.basename(path)
        license, notices = if name == EMULATOR_ARCHIVE
                             ['Apache-2.0 AND BSD-3-Clause', ['otp/LICENSE.txt', 'littlefs/LICENSE.md']]
                           else
                             ['Apache-2.0', ['otp/LICENSE.txt']]
                           end
        Archive.new(path: path, label: "otp #{name}", license: license, status: 'permanent', notices: notices)
      end
      [*otp,
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
        'release_erofs_sha256' => medium.erofs, 'medium_sha256' => medium.path }
        .transform_values { |path| Digest::SHA256.file(path).hexdigest }
    end

    # The directory a build packed into, as OutputDirectory.prepare resolved it: the real
    # path, which may differ from the spelling its caller passed.
    def built_directory(built) = File.dirname(built.archive)
  end
end
