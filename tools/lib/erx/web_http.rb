# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'web_inventory'

module Erx
  # `tools/erx web`, the host tool's front end of the web client (docs/design-web.md,
  # "The host tool's front end"). Web::Http reads a browser's request and Web::Gate
  # decides its answer, both pure; Web::Socket deframes the WebSocket; Web::Inventory
  # holds the client's files; Web::Server and Web::Relay are the effects.
  module Web
    # The HTTP/1.1 subset the front end speaks: one GET per connection, no body, with
    # Connection: close. Every byte of a request is a browser's, or any local page's or
    # process's, so the reader is bounded and refuses what it does not take with a
    # Refusal whose text is the reader's own, never a byte of the request.
    module Http
      LINE_MAX = 8192
      HEADERS_MAX = 32_768
      CRLF = "\r\n"
      END_OF_HEAD = "\r\n\r\n"
      VERSION = 'HTTP/1.1'
      TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/n
      # Origin-form only: a path of visible ASCII, which holds no space, control or '#'.
      TARGET = %r{\A/[\x21-\x22\x24-\x7e]*\z}n
      # A field value: visible ASCII, space and tab, and bytes of 0x80 and above, which
      # RFC 9110 allows and the gate never reads or echoes; no other control.
      VALUE = /\A[\t\x20-\x7e\x80-\xff]*\z/n
      # The only headers kept: those the gate reads, and those that would mean a body.
      # Any other is checked for its syntax and dropped; one of these sent twice is a
      # Refusal, so no two readers of a request can disagree on its value.
      READ = %w[host origin cookie upgrade connection sec-websocket-key sec-websocket-version
                content-length transfer-encoding].freeze

      # path is the target before any '?', query what follows it or nil; rest is what the
      # connection sent after the head, which only a WebSocket may use.
      Request = Data.define(:method, :path, :query, :headers, :rest)
      # A request the reader or the gate does not take; reason is one line of ASCII of
      # erXos's own.
      Refusal = Data.define(:status, :reason)
      Response = Data.define(:status, :headers, :body)

      PHRASES = { 101 => 'Switching Protocols', 200 => 'OK', 303 => 'See Other', 400 => 'Bad Request',
                  403 => 'Forbidden', 405 => 'Method Not Allowed', 414 => 'URI Too Long',
                  503 => 'Service Unavailable' }.freeze

      # The headers every file and every refusal carries (docs/design-web.md, "Security",
      # W3). They are written here and nowhere else in the host tool.
      POLICY = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; " \
               "connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; " \
               "require-trusted-types-for 'script'; trusted-types 'none'"
      SECURITY = [['Content-Security-Policy', POLICY], ['X-Content-Type-Options', 'nosniff'],
                  ['Referrer-Policy', 'no-referrer'], ['Cross-Origin-Opener-Policy', 'same-origin'],
                  ['Cross-Origin-Resource-Policy', 'same-origin']].freeze
      NO_STORE = 'no-store'
      IMMUTABLE = 'max-age=31536000, immutable'

      module_function

      # The request at the start of buffer: nil while its head is incomplete and within
      # bounds, else a Request or a Refusal. Pure; buffer is whatever has arrived.
      def read(buffer)
        bytes = buffer.b
        # The request line: at most LINE_MAX bytes before its CRLF. While its CRLF has not
        # come, a line of LINE_MAX bytes may still have its CR in and its LF to come.
        line_end = bytes.index(CRLF)
        if line_end.nil?
          return bytes.bytesize > LINE_MAX + 1 ? Refusal.new(414, 'request line over 8 KiB') : nil
        end
        return Refusal.new(414, 'request line over 8 KiB') if line_end > LINE_MAX

        # The fields: at most HEADERS_MAX bytes from the request line's CRLF to the head's
        # end. While the end has not come, up to three of its bytes may be in already, so
        # the bound is the same however the bytes arrive.
        head_end = bytes.index(END_OF_HEAD, line_end)
        waiting = head_end.nil?
        fields_size = (head_end || bytes.bytesize) - line_end
        return Refusal.new(400, 'headers over 32 KiB') if fields_size > HEADERS_MAX + (waiting ? END_OF_HEAD.bytesize - 1 : 0)
        return nil if waiting

        # Each field line ends in CRLF, the last one's included, so the split's final
        # element is the empty text after it.
        fields = bytes.byteslice(line_end + 2, head_end - line_end).split(CRLF, -1)[0...-1]
        request(bytes.byteslice(0, line_end), fields, bytes.byteslice(head_end + 4..))
      end

      # The wire bytes of a response, with Content-Length and Connection: close.
      def encode(response)
        lines = ["#{VERSION} #{response.status} #{PHRASES.fetch(response.status)}"]
        response.headers.each { |name, value| lines << "#{name}: #{value}" }
        lines << "Content-Length: #{response.body.bytesize}" unless response.status == 101
        lines << 'Connection: close' unless response.status == 101
        (lines.join(CRLF) + END_OF_HEAD).b + response.body.b
      end

      # A file of the client's bundle.
      def file(file)
        cache = file.path == Inventory::INDEX ? NO_STORE : IMMUTABLE
        Response.new(200, [['Content-Type', file.content_type], ['Cache-Control', cache], *SECURITY], file.bytes)
      end

      # A refusal: its status and its one line of text.
      def refusal(refusal)
        headers = [['Content-Type', 'text/plain; charset=utf-8'], ['Cache-Control', NO_STORE], *SECURITY]
        headers << %w[Allow GET] if refusal.status == 405
        Response.new(refusal.status, headers, "#{refusal.reason}\n")
      end

      # The answer to the printed URL: the same path without its query, and the cookie.
      def see_other(path, cookie)
        Response.new(303, [['Location', path], ['Set-Cookie', cookie], ['Cache-Control', NO_STORE], *SECURITY], '')
      end

      # The upgrade's answer, RFC 6455 section 4.2.2, with no extension and no subprotocol.
      def switching(accept)
        Response.new(101, [%w[Upgrade websocket], %w[Connection Upgrade], ['Sec-WebSocket-Accept', accept]], '')
      end

      def request(line, fields, rest)
        method, target, version, *extra = line.split(/ /, -1)
        return Refusal.new(400, 'malformed request line') unless
          extra.empty? && method&.match?(TOKEN) && target&.match?(TARGET) && version == VERSION

        headers = headers(fields)
        return headers if headers.is_a?(Refusal)

        path, query = target.split('?', 2)
        Request.new(method: method, path: path, query: query, headers: headers.freeze, rest: rest)
      end

      def headers(fields)
        fields.each_with_object({}) do |field, kept|
          name, value = field.split(':', 2)
          return Refusal.new(400, 'malformed header') unless value && name.match?(TOKEN) && value.match?(VALUE)

          key = name.downcase
          next unless READ.include?(key)
          return Refusal.new(400, "#{key} sent twice") if kept.key?(key)

          kept[key] = value.strip
        end
      end
    end

    # The gate's decision for one request (W4): which file, refusal, cookie or upgrade
    # answers it. authority is "127.0.0.1:PORT", the only Host and, after "http://", the
    # only Origin it takes; token is the printed URL's secret and cookie the session
    # cookie's value, made apart at each start, so the token is in no response.
    Gate = Data.define(:authority, :token, :cookie, :inventory)

    class Gate
      # Never the secrets, so no message or test failure that shows a gate shows them.
      def inspect = "#<Erx::Web::Gate #{authority}>"
      alias to_s inspect

      # The WebSocket upgrade's answer, for the server to send once the machine took the
      # connection; rest is what the browser sent after the request's head.
      Upgrade = Data.define(:accept, :rest)
      WS_PATH = '/ws'
      WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
      # The base64 of 16 bytes (RFC 6455 section 4.1), which is all a key is checked for.
      WS_KEY = %r{\A[A-Za-z0-9+/]{21}[AQgw]==\z}

      # A Response, a Refusal, or an Upgrade. The Host check comes first, so a page whose
      # name an attacker rebound to the loopback address reads nothing (DNS rebinding).
      def answer(request)
        return Http::Refusal.new(400, 'Host is not this server') unless host?(request)
        return Http::Refusal.new(405, 'only GET is served') unless request.method == 'GET'
        return Http::Refusal.new(400, 'a GET carries no body') if
          request.headers.key?('content-length') || request.headers.key?('transfer-encoding')
        return login(request) if request.query
        return upgrade(request) if request.path == WS_PATH

        Http.file(inventory.file(request.path))
      end

      # The cookie the browser keeps: HttpOnly, so no script reads it; SameSite=Strict,
      # so no other site's page sends it. Named after the port, so two front ends on one
      # host do not overwrite each other's.
      def cookie_name = "erx_web_#{authority.split(':').last}"

      private

      def host?(request) = request.headers['host'] == authority

      def origin?(request) = request.headers['origin'] == "http://#{authority}"

      def cookie?(request)
        Gate.pairs(request.headers.fetch('cookie', '')).any? do |name, value|
          name == cookie_name && Gate.same_secret?(value, cookie)
        end
      end

      def token?(request) = Gate.same_secret?(request.query, "token=#{token}")

      # The printed URL's query sets the cookie and sends the browser on without the
      # query; any other query is a stale or forged URL.
      def login(request)
        return Http::Refusal.new(403, 'this URL is not the one erx web printed') unless token?(request)

        # A path that starts with two slashes, or a slash and a backslash, which a browser
        # reads as a slash, would name another host in Location.
        location = request.path.match?(%r{\A/[/\\]}) ? '/' : request.path
        Http.see_other(location, "#{cookie_name}=#{cookie}; HttpOnly; SameSite=Strict; Path=/")
      end

      # Authority first, so a page without the cookie or from another origin learns
      # nothing from how its upgrade is malformed (CSRF, cross-origin WebSockets).
      def upgrade(request)
        return Http::Refusal.new(403, 'the WebSocket needs the session cookie and this origin') unless
          cookie?(request) && origin?(request)

        headers = request.headers
        key = headers['sec-websocket-key'].to_s
        return Http::Refusal.new(400, 'not a WebSocket upgrade') unless
          headers['upgrade']&.casecmp?('websocket') && Gate.list(headers['connection']).include?('upgrade') &&
          headers['sec-websocket-version'] == '13' && key.match?(WS_KEY)

        Upgrade.new(accept: [Digest::SHA1.digest(key + WS_GUID)].pack('m0'), rest: request.rest)
      end

      class << self
        # Compares a secret in time that depends on neither value: both are hashed to 32
        # bytes and every byte is compared.
        def same_secret?(given, secret)
          Digest::SHA256.digest(given.to_s.b).bytes.zip(Digest::SHA256.digest(secret.b).bytes)
                        .reduce(0) { |difference, (left, right)| difference | (left ^ right) }.zero?
        end

        # A Cookie header's name and value pairs.
        def pairs(header) = header.split(';').map { |pair| pair.strip.split('=', 2) }.select { |pair| pair.size == 2 }

        # A comma-separated header's elements, lower case.
        def list(header) = header.to_s.split(',').map { |element| element.strip.downcase }

      end
    end
  end
end
