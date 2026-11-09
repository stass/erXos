# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
require 'tmpdir'
require 'digest'
require_relative '../../tools/lib/erx/web_server'

# `tools/erx web`'s reader, gate and deframer, and the server end to end against a
# scripted machine (docs/design-web.md, "The host tool's front end", W4 and
# "Verification and testing").
module WebFrontHelpers
  Etf = Erx::Etf
  Http = Erx::Web::Http
  WS = Erx::Web::Socket
  TOKEN = 'a' * 32
  COOKIE = 'b' * 32
  PORT = 4711
  AUTHORITY = "127.0.0.1:#{PORT}".freeze
  INDEX = '<!doctype html><title>erXos</title>'
  SCRIPT = 'console.log(1)'
  KEY = 'dGhlIHNhbXBsZSBub25jZQ=='

  def inventory = Erx::Web::Inventory.new([['index.html', INDEX], ['app-0123abcd.js', SCRIPT]])

  def gate(kind = Erx::Web::Gate) = kind.new(authority: AUTHORITY, token: TOKEN, cookie: COOKIE, inventory: inventory)

  def head(path, headers = {}) = head_of('GET', path, headers)

  def head_of(method, path, headers)
    lines = ["#{method} #{path} HTTP/1.1", *headers.map { |name, value| "#{name}: #{value}" }]
    "#{lines.join("\r\n")}\r\n\r\n".b
  end

  def upgrade_headers(authority: AUTHORITY, cookie: COOKIE, origin: "http://#{authority}")
    { 'Host' => authority, 'Origin' => origin, 'Cookie' => "other=1; erx_web_#{authority.split(':').last}=#{cookie}",
      'Upgrade' => 'websocket', 'Connection' => 'keep-alive, Upgrade', 'Sec-WebSocket-Key' => KEY,
      'Sec-WebSocket-Version' => '13' }.compact
  end

  # A masked frame, as a browser sends it.
  def client_frame(opcode, payload, final: true, mask: "\x37\xfa\x21\x3d".b)
    size = payload.bytesize
    length = if size < 126 then [0x80 | size].pack('C')
             elsif size <= 0xffff then [0x80 | 126, size].pack('Cn')
             else [0x80 | 127, size].pack('CQ>')
             end
    [(final ? 0x80 : 0) | opcode].pack('C') + length + mask + WS.unmask(payload.b, mask)
  end

  def answer(gate_value, bytes) = gate_value.answer(Http.read(bytes))
end

class WebHttpTest < Minitest::Test
  include WebFrontHelpers

  def test_a_request_is_read_whole_or_in_pieces
    bytes = head('/proc/kernel?x', 'Host' => AUTHORITY, 'X-Other' => 'dropped', 'Cookie' => 'a=1')
    request = Http.read(bytes)
    assert_equal ['GET', '/proc/kernel', 'x'], [request.method, request.path, request.query]
    assert_equal({ 'host' => AUTHORITY, 'cookie' => 'a=1' }, request.headers)
    (1...bytes.bytesize).each { |cut| assert_nil Http.read(bytes.byteslice(0, cut)) }
    assert_equal 'rest'.b, Http.read(bytes + 'rest').rest
  end

  def test_the_reader_bounds_line_and_headers
    assert_nil Http.read("GET /#{'x' * 8186}\r".b)
    assert_equal 414, Http.read("GET /#{'x' * 8200}".b).status
    assert_equal 414, Http.read("GET /#{'x' * 8200} HTTP/1.1\r\n\r\n".b).status
    long = "GET / HTTP/1.1\r\nX: #{'y' * 32_800}"
    assert_equal 400, Http.read(long.b).status
  end

  def test_the_reader_refuses_malformed_requests
    ['GET  / HTTP/1.1', 'GET / HTTP/1.0', 'GET http://x/ HTTP/1.1', 'GET /a#b HTTP/1.1', 'GET / HTTP/1.1 x',
     "GET /\x01 HTTP/1.1"].each do |line|
      assert_equal 400, Http.read("#{line}\r\nHost: #{AUTHORITY}\r\n\r\n".b).status, line
    end
    ["Host: a\r\nHost: b", " folded: x", "No colon", "Bad\x01: x", "X: a\rb", "X: a\nb"].each do |field|
      assert_equal 400, Http.read("GET / HTTP/1.1\r\n#{field}\r\n\r\n".b).status, field.inspect
    end
  end

  def test_responses_carry_the_policy_and_close
    bytes = Http.encode(Http.file(inventory.file('/')))
    assert_match %r{\AHTTP/1\.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n}, bytes
    assert_includes bytes, "Content-Security-Policy: default-src 'none'; script-src 'self';"
    assert_includes bytes, "X-Content-Type-Options: nosniff\r\n"
    assert_includes bytes, "Connection: close\r\n\r\n#{INDEX}"
    assert_includes Http.encode(Http.file(inventory.file('/app-0123abcd.js'))), 'Cache-Control: max-age=31536000, immutable'
  end
end

# W4's refusals, each with a seeded gate that skips its check and answers.
class WebGateTest < Minitest::Test
  include WebFrontHelpers

  def test_a_foreign_host_is_refused_before_anything_else
    ['localhost:4711', 'rebound.example:4711', '127.0.0.1:4712', '127.0.0.1', nil].each do |host|
      response = answer(gate, head_of('POST', "/?token=#{TOKEN}", { 'Host' => host }.compact))
      assert_equal 400, response.status, host.inspect
    end
    seeded = Class.new(Erx::Web::Gate) { def host?(_request) = true }
    assert_equal 303, answer(gate(seeded), head("/?token=#{TOKEN}", 'Host' => 'rebound.example:4711')).status
  end

  def test_only_get_without_a_body_is_served
    assert_equal 405, answer(gate, head_of('POST', '/', { 'Host' => AUTHORITY })).status
    assert_equal 405, answer(gate, head_of('HEAD', '/', { 'Host' => AUTHORITY })).status
    assert_equal 400, answer(gate, head('/', 'Host' => AUTHORITY, 'Content-Length' => '0')).status
    assert_equal 400, answer(gate, head('/', 'Host' => AUTHORITY, 'Transfer-Encoding' => 'chunked')).status
  end

  def test_any_path_outside_the_inventory_answers_index
    ['/', '/index.html', '/../../etc/passwd', '/%2e%2e/%2e%2e/etc/passwd', '/proc/kernel/log', '/app-0123abcd.js/x',
     '/APP-0123ABCD.JS', '/.git/config'].each do |path|
      response = answer(gate, head(path, 'Host' => AUTHORITY))
      assert_equal [200, INDEX], [response.status, response.body], path
    end
    assert_equal SCRIPT, answer(gate, head('/app-0123abcd.js', 'Host' => AUTHORITY)).body
  end

  def test_the_printed_token_sets_a_cookie_that_is_not_the_token
    response = answer(gate, head("/proc/x?token=#{TOKEN}", 'Host' => AUTHORITY))
    assert_equal 303, response.status
    headers = response.headers.to_h
    assert_equal '/proc/x', headers.fetch('Location')
    assert_equal "erx_web_4711=#{COOKIE}; HttpOnly; SameSite=Strict; Path=/", headers.fetch('Set-Cookie')
    refute_includes Http.encode(response), TOKEN
    ['//evil.example/', '/\\evil.example/'].each do |path|
      assert_equal '/', answer(gate, head("#{path}?token=#{TOKEN}", 'Host' => AUTHORITY)).headers.to_h.fetch('Location')
    end
    seeded = Class.new(Erx::Web::Gate) { def cookie = token }
    assert_includes Http.encode(answer(gate(seeded), head("/?token=#{TOKEN}", 'Host' => AUTHORITY))), TOKEN
  end

  def test_a_wrong_token_or_another_query_is_refused
    ["token=#{'c' * 32}", "token=#{TOKEN}&x=1", "x=1&token=#{TOKEN}", 'token=', 'x', ''].each do |query|
      assert_equal 403, answer(gate, head("/?#{query}", 'Host' => AUTHORITY)).status, query
    end
  end

  def test_the_upgrade_needs_the_cookie_and_the_origin
    upgrade = answer(gate, head('/ws', upgrade_headers))
    assert_instance_of Erx::Web::Gate::Upgrade, upgrade
    # RFC 6455 section 1.3's example.
    assert_equal 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=', upgrade.accept
    [upgrade_headers(cookie: nil), upgrade_headers(cookie: TOKEN), upgrade_headers(cookie: 'b' * 31),
     upgrade_headers(origin: nil), upgrade_headers(origin: 'http://rebound.example:4711'),
     upgrade_headers(origin: 'http://127.0.0.1:4712'), upgrade_headers(origin: 'null'),
     upgrade_headers.merge('Cookie' => "erx_web_4712=#{COOKIE}")].each do |headers|
      assert_equal 403, answer(gate, head('/ws', headers.compact)).status, headers.inspect
    end
    { origin?: upgrade_headers(origin: 'http://rebound.example:4711'), cookie?: upgrade_headers(cookie: nil) }.each do |check, headers|
      seeded = Class.new(Erx::Web::Gate) { define_method(check) { |_request| true } }
      assert_instance_of Erx::Web::Gate::Upgrade, answer(gate(seeded), head('/ws', headers)), check
    end
  end

  def test_a_malformed_upgrade_is_refused_after_authority
    [{ 'Upgrade' => 'h2c' }, { 'Connection' => 'keep-alive' }, { 'Sec-WebSocket-Version' => '8' },
     { 'Sec-WebSocket-Key' => 'short' }, { 'Sec-WebSocket-Key' => 'dGhlIHNhbXBsZSBub25jZR==' }].each do |change|
      assert_equal 400, answer(gate, head('/ws', upgrade_headers.merge(change))).status, change.inspect
    end
    assert_equal 403, answer(gate, head('/ws', upgrade_headers(cookie: nil).merge('Upgrade' => 'h2c'))).status
  end

  def test_secrets_compare_whole
    assert Erx::Web::Gate.same_secret?(COOKIE, COOKIE)
    [nil, '', COOKIE[0...-1], "#{COOKIE}b", COOKIE.upcase].each { |other| refute Erx::Web::Gate.same_secret?(other, COOKIE) }
  end
end

class WebSocketTest < Minitest::Test
  include WebFrontHelpers

  def deframe(bytes) = WS::Deframer.new.feed(bytes)

  def test_messages_whole_and_in_fragments
    assert_equal [WS::Message.new('hello'.b)], deframe(client_frame(2, 'hello'))
    pieces = client_frame(2, 'he', final: false) + client_frame(9, 'p') + client_frame(0, 'll', final: false) +
             client_frame(0, 'o')
    assert_equal [WS::Ping.new('p'.b), WS::Message.new('hello'.b)], deframe(pieces)
    deframer = WS::Deframer.new
    events = pieces.each_char.flat_map { |byte| deframer.feed(byte) }
    assert_equal [WS::Ping.new('p'.b), WS::Message.new('hello'.b)], events
    big = 'x' * WS::MESSAGE_MAX
    assert_equal [WS::Message.new(big.b)], deframe(client_frame(2, big))
  end

  def test_a_declared_length_past_the_bound_fails_before_its_payload
    header = [0x82, 0x80 | 127, 1 << 40].pack('CCQ>') + "\0\0\0\0"
    deframer = WS::Deframer.new
    assert_equal [WS::TOO_BIG], deframer.feed(header).map(&:code)
    assert deframer.ended?
    assert_empty deframer.feed('more')
    over = client_frame(2, 'x' * 40_000, final: false) + client_frame(0, 'y' * 30_000).byteslice(0, 14)
    assert_equal [WS::TOO_BIG], deframe(over).map(&:code)
  end

  def test_protocol_breaks_close_with_the_rfcs_code
    { "\x82\x05hello" => 1002, client_frame(1, 'text') => 1003, client_frame(0, 'x') => 1002,
      client_frame(2, 'a', final: false) + client_frame(2, 'b') => 1002, client_frame(3, '') => 1002,
      client_frame(9, 'x' * 126) => 1002, client_frame(9, 'x', final: false) => 1002,
      client_frame(8, "\x03") => 1002, client_frame(8, [999].pack('n')) => 1002,
      client_frame(8, [1000].pack('n') + "\xff".b) => 1007, [0xc2, 0x81].pack('CC') + "\0\0\0\0x" => 1002,
      [0x82, 0x80 | 126, 5].pack('CCn') + "\0\0\0\0hello" => 1002 }.each do |bytes, code|
      assert_equal [code], deframe(bytes.b).map(&:code), bytes.inspect
    end
    assert_equal [WS::Closed.new(1001)], deframe(client_frame(8, [1001].pack('n') + 'bye'))
    assert_equal [WS::Closed.new(nil)], deframe(client_frame(8, ''))
  end

  def test_the_front_ends_frames_are_unmasked
    assert_equal "\x82\x03abc".b, WS.binary('abc')
    assert_equal [0x82, 126, 200].pack('CCn') + ('x' * 200), WS.binary('x' * 200)
    assert_equal [0x82, 127, 70_000].pack('CCQ>') + ('x' * 70_000), WS.binary('x' * 70_000)
    assert_equal "\x88\x02\x03\xf3".b, WS.close(1011)
  end
end

class WebInventoryTest < Minitest::Test
  include WebFrontHelpers

  def bundle(directory, files, list: nil)
    files.each { |path, bytes| File.binwrite(File.join(directory, path), bytes) }
    lines = files.map { |path, bytes| "#{Digest::SHA256.hexdigest(bytes)}  #{path}" }
    File.binwrite(File.join(directory, 'inventory.txt'), list || "#{lines.join("\n")}\n")
  end

  def test_the_bundle_is_read_once_and_checked
    Dir.mktmpdir do |directory|
      bundle(directory, { 'index.html' => INDEX, 'app.js' => SCRIPT })
      loaded = Erx::Web::Inventory.load(directory)
      assert_equal %w[index.html app.js], loaded.paths
      File.binwrite(File.join(directory, 'app.js'), 'changed')
      assert_equal SCRIPT, loaded.file('/app.js').bytes
      assert_raises(Erx::Error) { Erx::Web::Inventory.load(directory) }
    end
  end

  def test_names_kinds_and_links_are_refused
    Dir.mktmpdir do |directory|
      assert_raises(Erx::Error) { Erx::Web::Inventory.load(directory) }
      bundle(directory, { 'index.html' => INDEX }, list: "#{'0' * 64}  ../index.html\n")
      assert_raises(Erx::Error) { Erx::Web::Inventory.load(directory) }
      File.symlink('/etc/hosts', File.join(directory, 'hosts.txt'))
      digest = Digest::SHA256.hexdigest(File.binread('/etc/hosts'))
      bundle(directory, { 'index.html' => INDEX }, list: "#{Digest::SHA256.hexdigest(INDEX)}  index.html\n#{digest}  hosts.txt\n")
      assert_raises(Erx::Error) { Erx::Web::Inventory.load(directory) }
    end
    [[['index.html', INDEX], ['a.svg', '<svg/>']], [['app.js', SCRIPT]], [['index.html', INDEX], ['.x.js', SCRIPT]],
     [['index.html', INDEX], ['index.html', INDEX]]].each do |entries|
      assert_raises(Erx::Error, entries.inspect) { Erx::Web::Inventory.new(entries) }
    end
  end
end

# The machine's end of the host link with a web facet: the design's protocol, which the
# guest's web domain does not serve yet. It answers hello, {open, web} with facet 1, and
# connect, data and close on it with ok; it casts each message's bytes back, and ends a
# connection whose message is "end" with web_closed. It grants credit for every byte.
class FakeMachine
  Frame = Erx::HostlinkFrame
  Etf = Erx::Etf
  OK = Etf::Atom.new(name: 'ok')

  attr_reader :calls

  def initialize(io, refuse_open: false, refuse_connect: false)
    @io = io
    @refuse_open = refuse_open
    @refuse_connect = refuse_connect
    @deframer = Frame::Deframer.new(:target)
    @receiver = Frame::Receiver.new
    @calls = Queue.new
    @sender = nil
    @received = 0
  end

  def run
    loop do
      bytes = @io.readpartial(65_536)
      opened = @deframer.feed(bytes).select { |frame| frame.is_a?(Frame::Frame) }.map { |frame| take(frame) }.any?(:hello)
      @received = opened ? 0 : @received + bytes.bytesize
      @io.write(@sender.frame(:credit, '', target: @received % (1 << 32))) if @sender && !opened
    end
  rescue EOFError, IOError
    nil
  end

  private

  def take(frame)
    case @receiver.accept(frame)
    in Frame::Hello[message]
      hello(Etf.decode(message.payload).elements[1])
      :hello
    in Frame::Message => message if message.kind == :call
      @calls << Etf.decode(message.payload)
      answer(message, Etf.decode(message.payload))
    else
      nil
    end
  end

  def answer(message, term)
    reply = case term
            in Etf::Tuple[[Etf::Atom[name: 'open'], Etf::Atom[name: 'web']]] if message.target.zero?
              @refuse_open ? error('badarg') : tuple(OK, tuple(Etf::Atom.new(name: '$host_cap'), 1))
            in Etf::Tuple[[Etf::Atom[name: 'connect'], Integer]] if message.target == 1
              @refuse_connect ? error('limit') : OK
            in Etf::Tuple[[Etf::Atom[name: 'data'], Integer => number, String => bytes]] if message.target == 1
              cast(bytes == 'end' ? tuple(Etf::Atom.new(name: 'web_closed'), number, Etf::Atom.new(name: 'normal')) :
                                    tuple(Etf::Atom.new(name: 'web'), number, bytes))
              OK
            in Etf::Tuple[[Etf::Atom[name: 'close'], Integer]] if message.target == 1 then OK
            else error('noproc')
            end
    @io.write(@sender.message(:reply, Etf.encode(reply), id: message.id, target: message.target).join)
  end

  def cast(term) = @io.write(@sender.message(:cast, Etf.encode(term), id: 0, target: 1).join)

  def hello(nonce)
    session = Random.bytes(16)
    reply = tuple(Etf::Atom.new(name: 'hello'), nonce, session, 'ab'.b, Etf::Map.new(pairs: []))
    @io.write(Frame::Sender.new(Frame::SESSION_ZERO).message(:reply, Etf.encode(reply), id: 1, target: 0).join)
    @receiver.session = session
    @sender = Frame::Sender.new(session)
  end

  def tuple(*elements) = Etf::Tuple.new(elements: elements)

  def error(reason) = tuple(Etf::Atom.new(name: 'error'), Etf::Atom.new(name: reason))
end

# The server over real sockets: a browser's requests over TCP on the loopback address,
# the machine a FakeMachine over a socket pair.
class WebServerTest < Minitest::Test
  include WebFrontHelpers

  TIMING = Erx::Web::Server::Timing.new(request: 0.5, ping: 30, idle: 60)

  def setup
    @lines = Queue.new
  end

  def with_server(timing: TIMING, **machine_options)
    host, target = UNIXSocket.pair
    machine = FakeMachine.new(target, **machine_options)
    machine_thread = Thread.new { machine.run }
    relay = Erx::Web::Relay.new(link: Erx::HostlinkClient.new(io: host, deadline: 2))
    relay.open
    server = Erx::Web::Server.new(relay: relay, inventory: inventory, out: @lines.method(:push), timing: timing)
    thread = Thread.new { server.serve }
    yield server, machine, target
  ensure
    server&.stop
    thread&.join(5)
    [host, target].each { |io| io&.close unless io&.closed? }
    machine_thread&.join(5)
  end

  def connect(server) = TCPSocket.new('127.0.0.1', server.port)

  # The whole answer of an HTTP exchange: the server closes after it.
  def exchange(server, bytes)
    socket = connect(server)
    socket.write(bytes)
    socket.read
  ensure
    socket&.close
  end

  def cookie_of(server)
    answer = exchange(server, head("/?token=#{token_of(server)}", 'Host' => "127.0.0.1:#{server.port}"))
    answer[/^Set-Cookie: erx_web_\d+=(\h+);/, 1]
  end

  def token_of(server) = server.url[/token=(\h+)\z/, 1]

  # An upgraded WebSocket and the answer's head.
  def open_socket(server, cookie: cookie_of(server))
    socket = connect(server)
    socket.write(head('/ws', upgrade_headers(cookie: cookie, authority: "127.0.0.1:#{server.port}")))
    answer = +''
    answer << socket.readpartial(1) until answer.end_with?("\r\n\r\n")
    [socket, answer]
  end

  # The next frame the server sent: [opcode, payload].
  def read_frame(socket)
    first, second = socket.read(2).unpack('CC')
    length = case second & 0x7f
             when 126 then socket.read(2).unpack1('n')
             when 127 then socket.read(8).unpack1('Q>')
             else second & 0x7f
             end
    [first & 0x0f, socket.read(length)]
  end

  def test_the_url_is_on_loopback_with_a_fresh_token
    with_server do |server, _machine|
      assert_match %r{\Ahttp://127\.0\.0\.1:\d+/\?token=\h{32}\z}, server.url
      authority = "127.0.0.1:#{server.port}"
      assert_includes exchange(server, head('/', 'Host' => authority)), INDEX
      assert_match(/\AHTTP\/1\.1 400 /, exchange(server, head('/', 'Host' => "rebound.example:#{server.port}")))
      refute_equal cookie_of(server), token_of(server)
      private_address = ::Socket.ip_address_list.find(&:ipv4_private?)
      assert_raises(SystemCallError) { TCPSocket.new(private_address.ip_address, server.port) } if private_address
    end
  end

  def test_a_message_goes_to_the_machine_and_back
    with_server do |server, machine|
      socket, answer = open_socket(server)
      assert_match %r{\AHTTP/1\.1 101 Switching Protocols\r\n}, answer
      assert_equal Etf::Tuple.new(elements: [Etf::Atom.new(name: 'open'), Etf::Atom.new(name: 'web')]), machine.calls.pop
      number = machine.calls.pop.elements[1]
      big = Random.bytes(WS::MESSAGE_MAX)
      socket.write(client_frame(2, 'hi') + client_frame(2, big[0, 40_000], final: false) + client_frame(0, big[40_000..]))
      assert_equal [2, 'hi'.b], read_frame(socket)
      assert_equal [2, big], read_frame(socket)
      assert_equal Etf::Tuple.new(elements: [Etf::Atom.new(name: 'data'), number, 'hi'.b]), machine.calls.pop
      socket.write(client_frame(9, 'p'))
      assert_equal [10, 'p'.b], read_frame(socket)
      socket.write(client_frame(8, [1000].pack('n')))
      assert_equal [8, [1000].pack('n')], read_frame(socket)
      machine.calls.pop
      assert_equal Etf::Tuple.new(elements: [Etf::Atom.new(name: 'close'), number]), machine.calls.pop
    ensure
      socket&.close
    end
  end

  def test_the_machine_ends_a_connection
    with_server do |server, _machine|
      socket, = open_socket(server)
      socket.write(client_frame(2, 'end'))
      assert_equal [8, [1000].pack('n')], read_frame(socket)
    ensure
      socket&.close
    end
  end

  def test_a_websocket_outlives_the_request_deadline_and_a_slow_request_does_not
    with_server do |server, _machine|
      slow = connect(server)
      slow.write('GET / HTTP/1.1')
      socket, = open_socket(server)
      sleep(TIMING.request + 0.3)
      assert_equal '', slow.read
      socket.write(client_frame(2, 'later'))
      assert_equal [2, 'later'.b], read_frame(socket)
    ensure
      [slow, socket].each { |io| io&.close }
    end
  end

  def test_four_websockets_at_most_and_the_upgrade_needs_its_cookie
    with_server do |server, _machine|
      cookie = cookie_of(server)
      sockets = Array.new(4) { open_socket(server, cookie: cookie).first }
      _, answer = open_socket(server, cookie: cookie)
      assert_match(/\AHTTP\/1\.1 503 /, answer)
      _, answer = open_socket(server, cookie: 'c' * 32)
      assert_match(/\AHTTP\/1\.1 403 /, answer)
    ensure
      sockets&.each(&:close)
    end
  end

  def test_a_refused_connection_is_never_upgraded
    with_server(refuse_connect: true) do |server, _machine|
      _, answer = open_socket(server)
      assert_match(/\AHTTP\/1\.1 503 /, answer)
    end
  end

  def test_a_broken_link_closes_every_websocket_with_1011
    with_server do |server, _machine, target|
      sockets = Array.new(2) { open_socket(server).first }
      target.close
      sockets.each { |socket| assert_equal [8, [1011].pack('n')], read_frame(socket) }
      assert_match(/host link/, @lines.pop)
      _, answer = open_socket(server)
      assert_match(/\AHTTP\/1\.1 503 /, answer)
    ensure
      sockets&.each(&:close)
    end
  end

  def test_a_machine_without_the_facet_stops_the_start
    host, target = UNIXSocket.pair
    machine_thread = Thread.new { FakeMachine.new(target, refuse_open: true).run }
    relay = Erx::Web::Relay.new(link: Erx::HostlinkClient.new(io: host, deadline: 2))
    error = assert_raises(Erx::Web::Relay::Down) { relay.open }
    assert_match(/offers no web facet: it answered \{error,badarg\}/, error.message)
  ensure
    [host, target].each { |io| io&.close }
    machine_thread&.join(5)
  end

  def test_no_line_the_server_prints_holds_a_secret
    with_server do |server, _machine, target|
      cookie = cookie_of(server)
      socket, = open_socket(server, cookie: cookie)
      target.close
      read_frame(socket)
      lines = Array.new(@lines.size) { @lines.pop }
      refute_empty lines
      lines.each { |line| refute_includes line, token_of(server) }
      lines.each { |line| refute_includes line, cookie }
    ensure
      socket&.close
    end
  end
end
