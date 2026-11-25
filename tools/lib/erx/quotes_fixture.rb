# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'openssl'
require 'socket'

module Erx
  # The offline HTTPS fixture of the live quotes' QEMU cell (the dashboard example's README, "The
  # QEMU cell"): a TLS server on the host's loopback that answers Kraken's Ticker requests
  # for the pairs of erx_quotes_table with canned bodies in Kraken's shape, under a chain
  # made here for api.kraken.com. The guest reaches it through QEMU's guest forward for the
  # table's address (QemuPlan::Relay), and trusts it through the root file root writes,
  # which the cell's test image adds to its trust store (ProductionImage#build_medium).
  module QuotesFixture
    HOST = 'api.kraken.com'
    # Each quote of erx_quotes_table: the pair its URL asks for, the key Kraken answers
    # under, the last trade and the day's opening price as Kraken writes them, and the
    # price as the screen and the quotes log line show it (erx_dashboard_view:price/2).
    Quote = Data.define(:name, :pair, :key, :last, :open, :shown)
    QUOTES = [Quote.new(name: 'btc', pair: 'XBTUSD', key: 'XXBTZUSD', last: '64412.50000', open: '63000.00000', shown: '64,412.50'),
              Quote.new(name: 'eth', pair: 'ETHUSD', key: 'XETHZUSD', last: '3105.25000', open: '3000.00000', shown: '3,105.25'),
              Quote.new(name: 'sol', pair: 'SOLUSD', key: 'SOLUSD', last: '142.75000', open: '140.00000', shown: '142.75')].freeze
    # A body longer than the 65,536 bytes erx_quotes takes (max_body_size), with its
    # content-length, so httpc refuses it and the quote shows `answer too big`.
    TOO_BIG = 70_000
    # The chain's validity: from the epoch, so a guest whose clock is unset trusts it, to
    # the end of 9999 (RFC 5280's no well-defined expiration), which X.509 writes as a
    # GeneralizedTime. A UTCTime end would not do: public_key reads its two-digit year in a
    # window around the reader's own year (pubkey_cert:sliding_year_window/1), so a guest
    # whose clock reads 1970 takes 2049 for 1949 and refuses the chain as expired.
    NOT_BEFORE = Time.at(0).utc
    NOT_AFTER = Time.utc(9999, 12, 31, 23, 59, 59)
    # The longest request head the server reads before it gives up on a connection.
    MAX_HEAD = 8 * 1024

    module_function

    # Kraken's Ticker answer for quote: `c` the last trade as [price, volume], `o` the
    # opening price (erx_quotes_table's paths).
    def body(quote)
      %({"error":[],"result":{"#{quote.key}":{"c":["#{quote.last}","0.01000000"],"o":"#{quote.open}"}}})
    end

    # The cell's quotes log lines once every quote is fresh (erx_quotes_view:lines/2).
    def fresh_lines = QUOTES.map { |quote| "quotes: #{quote.name} fresh #{quote.shown} kraken_#{quote.name}" }

    # The lines of a guest that does not trust the fixture's root: every quote refused.
    def refused_lines = QUOTES.map { |quote| "quotes: #{quote.name} no_data -- certificate" }

    # A root and a server certificate for HOST under it, both ECDSA P-256 with SHA-256, as
    # Kraken's are. Writes the root to root_path, as one PEM CERTIFICATE block (the trust
    # store's root form), and answers the server's SSL context.
    def chain(root_path)
      root_key, key = Array.new(2) { OpenSSL::PKey::EC.generate('prime256v1') }
      root = certificate(serial: 1, subject: 'CN=erXos quotes fixture root', key: root_key, issuer: nil, signer: root_key)
      leaf = certificate(serial: 2, subject: "CN=#{HOST}", key: key, issuer: root, signer: root_key)
      File.write(root_path, root.to_pem)
      OpenSSL::SSL::SSLContext.new.tap do |context|
        context.cert = leaf
        context.key = key
        context.extra_chain_cert = []
      end
    end

    def certificate(serial:, subject:, key:, issuer:, signer:)
      name = OpenSSL::X509::Name.parse(subject)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = serial
      certificate.subject = name
      certificate.issuer = issuer ? issuer.subject : name
      certificate.public_key = key
      certificate.not_before = NOT_BEFORE
      certificate.not_after = NOT_AFTER
      extensions = OpenSSL::X509::ExtensionFactory.new(issuer || certificate, certificate)
      leaf_extensions = [%w[basicConstraints CA:FALSE true], %w[keyUsage digitalSignature true],
                         %w[extendedKeyUsage serverAuth], ['subjectAltName', "DNS:#{HOST}"]]
      root_extensions = [%w[basicConstraints CA:TRUE true], %w[keyUsage keyCertSign,cRLSign true], %w[subjectKeyIdentifier hash]]
      (issuer ? leaf_extensions : root_extensions).each { |row| certificate.add_extension(extensions.create_extension(*row)) }
      certificate.sign(signer, OpenSSL::Digest.new('SHA256'))
      certificate
    end
    private_class_method :certificate

    # The TLS server on a loopback port: each connection's one request is answered and the
    # connection closed. A request for a quote's pair with a Host of HOST gets the next of
    # that quote's answers, the last one again once they run out: by default its body;
    # :too_big the TOO_BIG body. Anything else gets a 404. A connection the guest abandons,
    # a refused handshake among them, ends that connection alone.
    class Server
      attr_reader :port

      # answers maps a quote's name to its answers in order, each :body or :too_big.
      def initialize(context:, answers: {})
        @context = context
        @answers = QUOTES.to_h { |quote| [quote.pair, [quote, answers.fetch(quote.name, [:body]).dup]] }
        @lock = Mutex.new
        @requests = Hash.new(0)
      end

      # How many requests each pair received, for a failed cell's note.
      def requests = @lock.synchronize { @requests.dup }

      def start
        @listener = TCPServer.new('127.0.0.1', 0)
        @port = @listener.addr[1]
        @accept = Thread.new { serve(OpenSSL::SSL::SSLServer.new(@listener, @context).tap { |ssl| ssl.start_immediately = false }) }
        self
      end

      def stop
        @accept&.kill
        @listener&.close
      end

      private

      def serve(server)
        loop do
          socket = server.accept
          Thread.new { answer(socket) }
        end
      end

      def answer(socket)
        socket.sync_close = true
        socket.accept
        head = read_head(socket)
        socket.write(response(head))
      rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def read_head(socket)
        head = +''
        head << socket.readpartial(1024) until head.include?("\r\n\r\n") || head.bytesize > MAX_HEAD
        head
      end

      def response(head)
        pair = head[%r{\AGET /0/public/Ticker\?pair=([A-Z]+) HTTP/1\.1\r\n}, 1]
        entry = pair && head.match?(/^host: #{Regexp.escape(HOST)}\r$/i) && @answers[pair]
        return reply(404, 'not found') unless entry

        quote, queue = entry
        answer = @lock.synchronize do
          @requests[pair] += 1
          queue.size > 1 ? queue.shift : queue.first
        end
        reply(200, answer == :too_big ? 'x' * TOO_BIG : QuotesFixture.body(quote))
      end

      def reply(status, body)
        "HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Not Found'}\r\ncontent-type: application/json\r\n" \
          "content-length: #{body.bytesize}\r\nconnection: close\r\n\r\n#{body}"
      end
    end
  end
end
