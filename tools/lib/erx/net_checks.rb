# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'origin_unwraps'

module Erx
  # The build checks of the network stack's application, erx_net
  # (docs/design-network-stack.md, "Build checks"):
  #
  # * atoms: no module of erx_net names binary_to_atom, list_to_atom or
  #   binary_to_term, so no atom is ever made from packet data;
  # * seq-wrap: only erx_tcp_seq does sequence-space wrap arithmetic, so no
  #   other TCP module (erx_tcp and erx_tcp_*) spells 2^31, 2^32 - 1 or 2^32
  #   as an integer literal in any base, or shifts left by a literal 31 or 32;
  # * notices: the FreeBSD files a module's header names, one
  #   "%% FreeBSD: PATH" line each, are the files NOTICE-freebsd lists for
  #   that module, and the reverse; any other line naming "FreeBSD:" (a
  #   marker with more after the path, or one below the header) is refused,
  #   so a malformed claim never reads as no claim;
  # * random: no module of erx_net names rand or crypto, since its random
  #   values come from erx_net_rand, but the portable erx_bytes, whose
  #   entropy/1 is crypto's generator outside erXos, names crypto; and only
  #   erx_net_clock calls
  #   erx_bytes:entropy, so every key passes the clock's seam,
  #   to key a generator or draw a stack-wide secret in their initialisation;
  # * grant-key: in the client application, erx_net_client, only erx_inet
  #   calls application:get_env, get_all_env or get_key, or names
  #   erx_net:local_grant, the registered erx_net_grant or
  #   erx_net_client_erxos:grant, and only erx_net_client_erxos, which answers
  #   the key on erXos from the `net` facet, calls erx:cap or erx:caps, so only
  #   erx_inet reads the `grant` key and knows the grant's pid, and every answer
  #   of the grant passes erx_sock_admit through erx_inet:call/1;
  # * call-timeout: in erx_net and erx_net_client, every gen_server:call and
  #   gen_statem:call has three arguments and every gen:call four, the last
  #   the literal `infinity`, and no `fun` names one of them, so no wait of
  #   the stack or its clients ends on a clock of its own;
  # * payload-copy: the modules a TCP payload passes through (erx_tcp and
  #   erx_tcp_*, erx_net_frame, erx_net_tx, erx_net_driver, erx_net_if,
  #   erx_net_input, the transports, and the client's erx_gen_tcp and
  #   erx_gen_tcp_core, the socket process) call iolist_to_binary/1,
  #   list_to_binary/1, binary:copy/1,2, binary:list_to_bin/1 or
  #   erlang:iolist_to_iovec/1 only in the functions COPY_SITES lists, so a
  #   payload byte is copied only where the fast path's design says
  #   (docs/design-network-fastpath.md, "Copies");
  # * origin: in erx_net and erx_net_client, only erx_net_admit and
  #   erx_sock_admit name the atom erx_origin, bare or quoted, so only they take
  #   apart the envelope of a message from another domain (D18).
  #
  # Like DeviceCallers these read the source text with comments removed, and
  # catch a slip, not a determined bypass that builds a name from pieces. The
  # atoms check keeps strings and quoted atoms, since `apply(erlang,
  # 'list_to_atom', ...)` names the function as surely as a call does; the
  # seq-wrap check blanks them, since a literal inside a string is no
  # arithmetic. The origin check reads code as OriginUnwraps does, comments and
  # strings gone and quoted atoms kept, so a module's documentation may name the
  # envelope. The call-timeout check splits a call's arguments at the commas
  # outside brackets, so a call holding a `fun` or `case` with a comma among
  # its arguments is refused rather than misread.
  module NetChecks
    APPLICATION = 'erlang/apps/erx_net'
    NOTICE = "#{APPLICATION}/NOTICE-freebsd"
    SCOPE = "#{APPLICATION}/**/*.{erl,hrl}"
    CLIENT_APPLICATION = 'erlang/apps/erx_net_client'
    CLIENT_SCOPE = "#{CLIENT_APPLICATION}/**/*.{erl,hrl}"
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    ATOM_MAKERS = /(?<![A-Za-z0-9_@])(binary_to_atom|list_to_atom|binary_to_term)(?![A-Za-z0-9_@])/
    RANDOM_MODULES = /(?<![A-Za-z0-9_@])(rand|crypto)(?![A-Za-z0-9_@])/
    # The one module that may name crypto: the host's generator behind entropy/1
    # (design-network-stack.md, "Build checks").
    CRYPTO_CALLER = "#{APPLICATION}/portable/erx_bytes.erl"
    ENTROPY_CALL = /(?<![A-Za-z0-9_@])erx_bytes\s*:\s*entropy(?![A-Za-z0-9_@])/
    # The one module that draws entropy (design-network-stack.md, "The clock").
    ENTROPY_CALLERS = %w[erx_net_clock].freeze
    # The TCP modules the seq-wrap rule covers, and the one module it lets do
    # the arithmetic.
    TCP_SOURCE = /\Aerx_tcp(?:_[a-z0-9_]+)?\.(?:erl|hrl)\z/
    SEQ_OWNER = 'erx_tcp_seq.erl'
    WRAP_VALUES = [2**31, 2**32 - 1, 2**32].freeze
    WRAP_SHIFTS = [31, 32].freeze
    # An Erlang integer literal (otp/lib/stdlib/src/erl_scan.erl): Base#Digits
    # or decimal digits, either with _ separators. It starts after no name
    # character, # or dot (so not inside a name, a based literal or a float's
    # fraction), and ends before no name character or # and before no dot
    # followed by a digit (a float); a dot ending a form still ends it.
    INTEGER = /
      (?<![A-Za-z0-9_@\#.])
      (?:(?<base>\d+)\#(?<based>[0-9A-Za-z]+(?:_[0-9A-Za-z]+)*) | (?<decimal>\d+(?:_\d+)*))
      (?![A-Za-z0-9_\#]|\.\d)
    /x
    # A left shift of an integer literal, through any spacing or line break
    # and an optional parenthesis.
    SHIFT = /\bbsl\b\s*\(?\s*(?=\d)/

    # The modules that may name the envelope of a message from another domain,
    # one on each side of the stack (design-network-stack.md, "Build checks").
    ORIGIN_OWNERS = %W[#{APPLICATION}/src/erx_net_admit.erl #{CLIENT_APPLICATION}/src/erx_sock_admit.erl].freeze

    # The one client module that reads the application's environment, and so
    # the `grant` key (design-network-stack.md, "Answers from the grant").
    GRANT_KEY_READER = "#{CLIENT_APPLICATION}/src/erx_inet.erl"
    GRANT_READ = /(?<![A-Za-z0-9_@])(?:application\s*:\s*(?:get_env|get_all_env|get_key)|erx_net\s*:\s*local_grant|erx_net_grant|erx_net_client_erxos\s*:\s*grant)(?![A-Za-z0-9_@])/
    # The one client module that reads the domain's facets, to answer the
    # `grant` key on erXos (design-network-stack.md, "Answers from the grant").
    FACET_READER = "#{CLIENT_APPLICATION}/erxos/erx_net_client_erxos.erl"
    FACET_READ = /(?<![A-Za-z0-9_@])erx\s*:\s*caps?(?![A-Za-z0-9_@])/
    # Each grant-key pattern with the one client module that may match it.
    GRANT_READERS = { GRANT_READ => GRANT_KEY_READER, FACET_READ => FACET_READER }.freeze
    # The calls whose timeout must be the literal infinity, each with the
    # arity at which the timeout is its last argument.
    CALL = /(?<![A-Za-z0-9_@])(?<module>gen_server|gen_statem|gen)\s*:\s*call(?![A-Za-z0-9_@])/
    CALL_ARITY = { 'gen_server' => 3, 'gen_statem' => 3, 'gen' => 4 }.freeze
    # The brackets an argument may hold commas inside, and what closes each.
    CLOSER = { '(' => ')', '[' => ']', '{' => '}', '<<' => '>>' }.freeze
    BRACKET = /<<|>>|[()\[\]{},]/

    # The modules a TCP payload passes through, by file name, and the calls that
    # copy one (docs/design-network-fastpath.md, "Copies").
    PAYLOAD_MODULE = /\A(?:erx_tcp(?:_[a-z0-9_]+)?|erx_net_(?:frame|tx|driver|if|input|pipe|loop)|erx_tap|erx_netmap|erx_virtio_net|erx_gen_tcp(?:_core)?)\.erl\z/
    COPY_CALL = /(?<![A-Za-z0-9_@])(?:(?:erlang\s*:\s*)?(?:iolist_to_binary|list_to_binary|iolist_to_iovec)|binary\s*:\s*(?:copy|list_to_bin))(?![A-Za-z0-9_@])/
    # The functions that may copy, each with its reason: a small piece copied out
    # so that it does not keep its frame alive, the pipe's frame to a test, the
    # frame layer's finishing of a checksum for a transport that does not finish,
    # the virtio transport's join of a frame of more binaries than a request
    # posts, the owner's iodata made into the one binary a send carries, and the
    # socket process's join of a delivery that spans pieces.
    COPY_SITES = {
      'erx_tcp_conn' => %w[compact], 'erx_tcp_reass' => %w[hold], 'erx_net_pipe' => %w[send],
      'erx_net_frame' => %w[finish], 'erx_virtio_net' => %w[segments],
      'erx_gen_tcp' => %w[send], 'erx_gen_tcp_core' => %w[split]
    }.freeze
    # The head of a function clause, which starts its line.
    CLAUSE_HEAD = /\A([a-z][A-Za-z0-9_@]*)\(/

    # A FreeBSD file named by a module's header, alone on its line.
    HEADER_MARK = /\A%+[ \t]*FreeBSD:[ \t]+(?<path>\S+)[ \t]*\z/
    FREEBSD_PATH = %r{\A[a-z0-9_]+(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)+\z}
    # The pin, and the release the translation was read from.
    NOTICE_KEYS = %w[tag commit archive-sha256
                     release-tag release-commit release-archive-sha256].freeze
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    # A FreeBSD commit, in full.
    COMMIT = /\A[0-9a-f]{40}\z/

    Violation = Data.define(:rule, :path, :line, :detail) do
      def to_s = "chokepoint net-#{rule}: #{[path, line].compact.join(':')}: #{detail}"
    end

    # NOTICE-freebsd parsed: its header keys and, per module, the FreeBSD
    # files it derives from, each with the functions translated from it.
    Notice = Data.define(:keys, :modules)

    module_function

    # Whether a path is one the checks read: an erx_net source or the notice.
    def covers?(path) = path == NOTICE || [SCOPE, CLIENT_SCOPE].any? { |scope| File.fnmatch?(scope, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text holding every
    # covered file.
    def violations(files)
      sources = files.select { |path, _| File.fnmatch?(SCOPE, path, GLOB_FLAGS) }
      client = files.select { |path, _| File.fnmatch?(CLIENT_SCOPE, path, GLOB_FLAGS) }
      [*atom_violations(sources), *random_violations(sources), *seq_violations(sources),
       *notice_violations(sources, notice: files[NOTICE]), *grant_key_violations(client),
       *call_timeout_violations(sources.merge(client)), *copy_violations(sources.merge(client)),
       *origin_violations(sources.merge(client))]
    end

    def origin_violations(sources)
      sources.reject { |path, _| ORIGIN_OWNERS.include?(path) }.flat_map do |path, text|
        OriginUnwraps.code_text(text).each_line.with_index(1).filter_map do |line, number|
          next unless line.match?(OriginUnwraps::ENVELOPE)

          Violation.new(rule: 'origin', path: path, line: number,
                        detail: "erx_origin outside #{ORIGIN_OWNERS.map { |owner| File.basename(owner, '.erl') }.join(' and ')}: " \
                                'only they take apart the envelope of a message from another domain')
        end
      end
    end

    def copy_violations(sources)
      sources.select { |path, _| File.basename(path).match?(PAYLOAD_MODULE) }.flat_map do |path, text|
        allowed = COPY_SITES.fetch(File.basename(path, '.erl'), [])
        code = calls_text(text)
        matches(code, COPY_CALL).filter_map do |line, call|
          function = enclosing_function(code, line)
          next if allowed.include?(function)

          Violation.new(rule: 'payload-copy', path: path, line: line,
                        detail: "#{call.delete(" \t\n")} in #{function || 'a declaration'}: a payload " \
                                'is copied only at the sites the fast path lists')
        end
      end
    end

    # The function whose clause holds line number `line` of code: the last clause head
    # at or above it, or nil above the first.
    def enclosing_function(code, line)
      code.each_line.first(line).reverse_each.lazy.filter_map { |text| text[CLAUSE_HEAD, 1] }.first
    end

    def grant_key_violations(client)
      GRANT_READERS.flat_map do |pattern, reader|
        client.reject { |path, _| path == reader }.flat_map do |path, text|
          matches(calls_text(text), pattern).map do |line, read|
            Violation.new(rule: 'grant-key', path: path, line: line,
                          detail: "#{read.delete(" \t\n")} outside #{File.basename(reader, '.erl')}: " \
                                  'only erx_inet:call/1 reaches the grant')
          end
        end
      end
    end

    def call_timeout_violations(sources)
      sources.flat_map do |path, text|
        code = calls_text(text)
        code.to_enum(:scan, CALL).filter_map do
          match = Regexp.last_match
          problem = call_problem(match[:module], code[match.end(0)..])
          next unless problem

          Violation.new(rule: 'call-timeout', path: path, line: code[0...match.begin(0)].count("\n") + 1,
                        detail: "#{match[:module]}:call #{problem}")
        end
      end
    end

    # Why the call of module_name whose text follows its name breaks the
    # call-timeout rule, or nil when it keeps it. A name followed by neither
    # an argument list nor a fun's arity is no call.
    def call_problem(module_name, rest)
      return 'is named by a fun, which hides its timeout' if rest.match?(%r{\A\s*/})
      return nil unless (open = rest[/\A\s*\(/])

      arguments = call_arguments(rest[open.size..])
      arity = CALL_ARITY.fetch(module_name)
      return 'has arguments whose brackets do not balance' unless arguments
      return "has #{arguments.size} arguments, not #{arity} with the timeout last" unless arguments.size == arity
      return "waits with #{arguments.last}, not the literal infinity" unless arguments.last == 'infinity'

      nil
    end

    # The arguments of a call, given its text after the opening parenthesis,
    # split at the commas outside brackets and stripped; nil when a bracket
    # closes out of order or the text ends first.
    def call_arguments(text)
      closers = []
      arguments = []
      start = 0
      text.to_enum(:scan, BRACKET).each do
        token = Regexp.last_match(0)
        at = Regexp.last_match.begin(0)
        if CLOSER.key?(token)
          closers.push(CLOSER.fetch(token))
        elsif token == ','
          next unless closers.empty?

          arguments << text[start...at].strip
          start = at + 1
        elsif closers.empty?
          return nil unless token == ')'

          return arguments << text[start...at].strip
        elsif closers.pop != token
          return nil
        end
      end
      nil
    end

    def atom_violations(sources)
      sources.flat_map do |path, text|
        DeviceCallers.code(text).each_line.with_index(1).filter_map do |line, number|
          next unless (name = line[ATOM_MAKERS, 1])

          Violation.new(rule: 'atoms', path: path, line: number,
                        detail: "#{name} in erx_net: no atom or term is made from packet data")
        end
      end
    end

    def random_violations(sources)
      sources.flat_map do |path, text|
        code = calls_text(text)
        (random_module_lines(path, code) + entropy_call_lines(path, code)).sort.map do |line, detail|
          Violation.new(rule: 'random', path: path, line: line, detail: detail)
        end
      end
    end

    def random_module_lines(path, code)
      matches(code, RANDOM_MODULES).filter_map do |line, name|
        [line, "#{name} in erx_net: random values come from erx_net_rand"] unless name == 'crypto' && path == CRYPTO_CALLER
      end
    end

    def entropy_call_lines(path, code)
      return [] if ENTROPY_CALLERS.include?(File.basename(path, '.erl'))

      matches(code, ENTROPY_CALL).map do |line, _|
        [line, "erx_bytes:entropy outside erx_net_clock (#{ENTROPY_CALLERS.join(', ')})"]
      end
    end

    # Each match of pattern in code, which may span lines, as [line of its start, text].
    def matches(code, pattern)
      code.to_enum(:scan, pattern).map { [code[0...Regexp.last_match.begin(0)].count("\n") + 1, Regexp.last_match(0)] }
    end

    def seq_violations(sources)
      sources.flat_map do |path, text|
        name = File.basename(path)
        next [] unless TCP_SOURCE.match?(name) && name != SEQ_OWNER

        code = blank_literals(text)
        offsets = integers(code).filter_map { |offset, value| offset if WRAP_VALUES.include?(value) }
        shifts = code.to_enum(:scan, SHIFT).filter_map do
          after = Regexp.last_match.end(0)
          after if integers(code[after..]).first&.then { |offset, value| offset.zero? && WRAP_SHIFTS.include?(value) }
        end
        (offsets + shifts).map { |offset| code[0...offset].count("\n") + 1 }.uniq.sort.map do |line|
          Violation.new(rule: 'seq-wrap', path: path, line: line, detail: 'sequence-space wrap arithmetic outside erx_tcp_seq')
        end
      end
    end

    # Each integer literal of code as [offset, value]; a literal erlc would
    # refuse has no value and is skipped.
    def integers(code)
      code.to_enum(:scan, INTEGER).filter_map do
        match = Regexp.last_match
        value = if match[:decimal]
                  match[:decimal].delete('_').to_i
                elsif (2..36).cover?(match[:base].to_i)
                  Integer(match[:based].delete('_'), match[:base].to_i, exception: false)
                end
        [match.begin(0), value] if value
      end
    end

    # The text with each comment, string and character literal blanked and
    # each quoted atom unquoted, every line kept: a call names its module as
    # an atom, quoted or not, and never inside a string such as a -moduledoc.
    def calls_text(text)
      text.b.gsub(DeviceCallers::LEXEME) do
        lexeme = Regexp.last_match(0)
        lexeme.start_with?("'") ? lexeme.delete("'") : lexeme.gsub(/[^\n]/, ' ')
      end
    end

    # The text with each comment, string, quoted atom and character literal
    # blanked and every line kept.
    def blank_literals(text)
      text.b.gsub(DeviceCallers::LEXEME) { Regexp.last_match(0).gsub(/[^\n]/, ' ') }
    end

    def notice_violations(sources, notice:)
      return [] if sources.empty? && notice.nil?
      return [notice_violation(nil, 'erx_net has sources but no NOTICE-freebsd')] if notice.nil?

      parsed, malformed = parse_notice(notice)
      return malformed unless malformed.empty?

      pairing_violations(sources, parsed)
    end

    # Each module's header against its notice entry, every notice entry
    # against a module that exists, and no two sources under one name.
    def pairing_violations(sources, notice)
      by_name = sources.group_by { |path, _| source_name(path) }
      twice = by_name.select { |_, entries| entries.size > 1 }.map do |name, entries|
        Violation.new(rule: 'notices', path: entries.first.first, line: nil,
                      detail: "#{entries.map(&:first).join(' and ')} share the name #{name}")
      end
      headers = by_name.transform_values { |entries| entries.first }
      from_headers = headers.flat_map do |name, (path, text)|
        files = header_files(text)
        listed = notice.modules.fetch(name, {}).keys
        mismatch = files.sort == listed.sort ? [] : [Violation.new(rule: 'notices', path: path, line: nil,
                                                                   detail: "the header names FreeBSD files #{files.sort.inspect} " \
                                                                           "but #{NOTICE} lists #{listed.sort.inspect} for #{name}")]
        mismatch + stray_markers(path, text)
      end
      orphans = (notice.modules.keys - headers.keys).map do |name|
        notice_violation(nil, "#{name} is listed but erx_net has no such module")
      end
      twice + from_headers + orphans
    end

    # The lines naming "FreeBSD:" that are not well-formed markers in the
    # leading comment block.
    def stray_markers(path, text)
      header = header_lines(text).size
      text.b.each_line.with_index(1).filter_map do |raw, number|
        line = raw.chomp
        next unless line.include?('FreeBSD:')
        next if number <= header && HEADER_MARK.match?(line)

        Violation.new(rule: 'notices', path: path, line: number,
                      detail: 'a FreeBSD marker is "%% FreeBSD: PATH" alone on a line of the leading comment block')
      end
    end

    # The module name of an .erl source, or the file name of an .hrl header.
    def source_name(path) = File.extname(path) == '.erl' ? File.basename(path, '.erl') : File.basename(path)

    # The leading comment block of a source: its lines up to the first that is
    # neither a comment nor blank.
    def header_lines(text) = text.b.each_line.map(&:chomp).take_while { |line| line.start_with?('%') || line.strip.empty? }

    # The FreeBSD files named in the leading comment block of a source.
    def header_files(text) = header_lines(text).filter_map { |line| line[HEADER_MARK, :path] }

    # The notice parsed, and its malformed lines. The format is line-based:
    # '#' starts a comment line; each of NOTICE_KEYS appears once with one
    # value; "port COMMIT PATH FUNCTION" names a function whose change between the
    # release and the pin was ported; "module NAME" starts a module's entry,
    # and each indented line under it is a FreeBSD path and the names of the
    # functions translated from it.
    def parse_notice(text)
      keys = {}
      modules = {}
      current = nil
      problems = []
      text.b.each_line.with_index(1) do |raw, number|
        line = raw.chomp
        next if line.strip.empty? || line.start_with?('#')

        words = line.split
        problem =
          if line.start_with?(' ', "\t")
            add_file(modules, current, words)
          elsif words.first == 'port'
            port_problem(words)
          elsif words.first == 'module'
            add_module(modules, words).tap { |refusal| current = refusal ? nil : words[1] }
          elsif NOTICE_KEYS.include?(words.first)
            add_key(keys, words)
          else
            'not a key, a port, a module or a file line'
          end
        problems << notice_violation(number, problem) if problem
      end
      missing = NOTICE_KEYS - keys.keys
      problems << notice_violation(nil, "missing #{missing.join(', ')}") unless missing.empty?
      [Notice.new(keys: keys.freeze, modules: modules.freeze), problems]
    end

    def add_key(keys, words)
      return "a #{words.first} line is \"#{words.first} VALUE\"" unless words.size == 2
      return "#{words.first} is given twice" if keys.key?(words.first)

      keys[words.first] = words[1]
      nil
    end

    # Each add_* helper records an accepted line in the table it is given and
    # returns nil, or returns why the line is refused.
    def add_module(modules, words)
      return 'a module line is "module NAME"' unless words.size == 2 && (NAME.match?(words[1]) || words[1].end_with?('.hrl'))
      return "module #{words[1]} is listed twice" if modules.key?(words[1])

      modules[words[1]] = {}
      nil
    end

    def port_problem(words)
      return 'a port line is "port COMMIT PATH FUNCTION"' unless words.size == 4
      return "#{words[1]} is not a FreeBSD commit of 40 hex digits" unless COMMIT.match?(words[1])
      return "#{words[2]} is not a FreeBSD source path" unless FREEBSD_PATH.match?(words[2])
      return "#{words[3]} is not a function name" unless NAME.match?(words[3])

      nil
    end

    def add_file(modules, current, words)
      return 'a file line before any module' unless current && modules.key?(current)
      path, *functions = words
      return "#{path} is not a FreeBSD source path" unless FREEBSD_PATH.match?(path)
      return "#{path} is listed twice for #{current}" if modules.fetch(current).key?(path)
      bad = functions.find { |name| !NAME.match?(name) }
      return "#{bad} is not a function name" if bad

      modules.fetch(current)[path] = functions.freeze
      nil
    end

    def notice_violation(line, detail) = Violation.new(rule: 'notices', path: NOTICE, line: line, detail: detail)
  end
end
