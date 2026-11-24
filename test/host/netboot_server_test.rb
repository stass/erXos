# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'socket'
require 'tmpdir'
require_relative '../../tools/lib/erx/netboot_server'

# The boot server of netboot's HTTP form (Erx::NetbootServer): the n-th download takes
# entry n and every one after the last takes the last, a download is bound to its entry
# at its signature's request, and no name but boot.sig and boot.img is ever answered.
# The decision and its effects run against a fake bootloader over queues in memory, and
# once over a real queue on the loopback.
class NetbootServerTest < Minitest::Test
  DECISION = Erx::NetbootServer::Decision
  PREFIX = 'erxos'
  BOARD = '192.168.2.2'

  # An image in memory, answering size and pread as the opened File does.
  class FakeImage
    def initialize(bytes)
      @bytes = bytes
    end

    def size = @bytes.bytesize
    def pread(length, offset) = @bytes.byteslice(offset, length)
    def close = nil
  end

  # Queues in memory, each target to its entries' [signature, image], nil for an entry
  # without a pair; link is the target the served link names, or nil.
  class FakeQueue
    attr_accessor :link

    def initialize(queues)
      @queues = queues
      @link = queues.keys.first
    end

    def served = DECISION::Served.new(target: link, entries: link ? @queues.fetch(link).size : 0)

    def open(target, entry)
      signature, image = @queues.fetch(target)[entry - 1]
      signature && Erx::NetbootEntry::Pair.new(signature: signature, image: FakeImage.new(image))
    end
  end

  # A connection's output that takes at most limit bytes, then fails as a client that
  # went away does.
  class Out
    def initialize(limit = nil)
      @bytes = ''.b
      @limit = limit
    end

    def write(data)
      raise Errno::EPIPE if @limit && @bytes.bytesize + data.bytesize > @limit

      @bytes << data
    end

    def status = @bytes[%r{\AHTTP/1\.1 (\d+)}, 1].to_i
    def body = @bytes.split("\r\n\r\n", 2).fetch(1, nil)
  end

  def setup
    @queue = FakeQueue.new('a' => entries('a', 3), 'b' => entries('b', 3), 'c' => [nil])
    @server = server(@queue)
  end

  def test_four_downloads_take_entries_one_two_three_and_three
    assert_equal ['image a1', 'image a2', 'image a3', 'image a3'], Array.new(4) { download }
  end

  def test_a_repeated_signature_request_takes_the_same_entry
    get('boot.sig')
    assert_equal ['image a1', 'image a2'], [download, download]
  end

  def test_a_change_of_the_link_within_a_download_leaves_it_its_signatures_image
    signature = get('boot.sig').body
    @queue.link = 'b'
    image = get('boot.img').body
    assert_equal ['image a1', Digest::SHA256.hexdigest(image)], [image, signature.lines.first.chomp]
    assert_equal 'image b1', download, 'a new target starts at its first entry'
  end

  def test_no_other_name_is_answered
    ["/#{PREFIX}/private.pem", "/#{PREFIX}/1/boot.img", "/#{PREFIX}//boot.sig", "/#{PREFIX}/boot.sig/",
     '/boot.sig', '/other/boot.sig', "/#{PREFIX}/boot.SIG", "/#{PREFIX}/../#{PREFIX}/boot.sig"].each do |path|
      assert_equal 404, answer(request('GET', path)).status, path
    end
    assert_equal 405, get('boot.sig', method: 'POST').status
    assert_equal 'image a1', download, 'refusals begin nothing'
  end

  def test_an_image_with_no_download_begun_is_refused
    assert_equal 404, get('boot.img').status
    get('boot.sig')
    assert_equal 404, get('boot.img', client: '192.168.2.3').status, "another client's image"
    assert_equal 'image a1', get('boot.img').body
    assert_equal 404, get('boot.img').status, 'an image goes out once per download'
  end

  def test_head_begins_nothing
    head = get('boot.sig', method: 'HEAD')
    assert_equal [200, ''], [head.status, head.body]
    assert_equal 404, get('boot.img').status
    get('boot.sig')
    assert_equal [200, ''], [get('boot.img', method: 'HEAD').status, get('boot.img', method: 'HEAD').body]
    assert_equal ['image a1', 'image a2'], [get('boot.img').body, download]
  end

  def test_an_entry_without_its_pair_and_an_empty_link_are_refused
    @queue.link = 'c'
    assert_equal [404, 404], [get('boot.sig').status, get('boot.img').status]
    @queue.link = nil
    assert_equal 404, get('boot.sig').status
  end

  def test_a_cut_image_keeps_its_download
    get('boot.sig')
    get('boot.img', out: Out.new(100))
    assert_equal ['image a1', 'image a2'], [get('boot.img').body, download]
  end

  # Over every sequence of eight requests and link changes, every image sent whole is
  # that of the signature sent before it.
  def test_every_whole_image_is_its_signatures
    events = %i[signature image cut change]
    events.repeated_permutation(8).each do |sequence|
      queue = FakeQueue.new('a' => entries('a', 2), 'b' => entries('b', 2))
      server = server(queue)
      signed = nil
      sequence.each do |event|
        case event
        in :change then queue.link = queue.link == 'a' ? 'b' : 'a'
        in :signature then signed = get('boot.sig', server: server).body&.lines&.first&.chomp
        in :cut then get('boot.img', server: server, out: Out.new(150))
        in :image
          out = get('boot.img', server: server)
          assert_equal signed, Digest::SHA256.hexdigest(out.body), sequence.inspect if out.status == 200
        end
      end
    end
  end

  def test_the_loopback_server_answers_an_entrys_pair_and_nothing_else
    Dir.mktmpdir('erx-netboot-serve-') do |scratch|
      queue = File.join(scratch, 'served.0123456789abcdef')
      FileUtils.mkdir_p(File.join(queue, '1'))
      image = Random.new(1).bytes(3 << 20)
      File.binwrite(File.join(queue, '1', 'boot.img'), image)
      File.write(File.join(queue, '1', 'boot.sig'), "#{Digest::SHA256.hexdigest(image)}\n")
      File.write(File.join(queue, '1', 'private.pem'), 'not served')
      File.write(File.join(scratch, 'private.pem'), 'not served')
      File.symlink(File.basename(queue), File.join(scratch, 'served'))
      lines = []
      listener = TCPServer.new('127.0.0.1', 0)
      server = Erx::NetbootServer::Server.new(queue: Erx::NetbootServer::LinkQueue.new(File.join(scratch, 'served')),
                                              prefix: PREFIX, log: ->(line) { lines << line })
      thread = Thread.new { server.listen(listener) }
      port = listener.addr[1]
      begin
        assert_equal [404, ''], fetch(port, 'GET /erxos/boot.img HTTP/1.1')
        assert_equal [200, "#{Digest::SHA256.hexdigest(image)}\n"], fetch(port, 'GET /erxos/boot.sig HTTP/1.1')
        assert_equal [200, image], fetch(port, 'GET /erxos/boot.img HTTP/1.1')
        ['GET /erxos/private.pem HTTP/1.1', 'GET /erxos/1/private.pem HTTP/1.1', 'GET /private.pem HTTP/1.1',
         'GET /erxos/%2e%2e/private.pem HTTP/1.1'].each { |line| assert_equal 404, fetch(port, line).first, line }
        assert_equal 400, fetch(port, "GET /erxos/boot.sig\e[2J HTTP/1.1").first
        assert_equal 405, fetch(port, 'DELETE /erxos/boot.sig HTTP/1.1').first
      ensure
        listener.close
        thread.join
      end
      assert(lines.any? { |line| line.include?('/erxos/boot.img 200 entry 1') }, lines.inspect)
      assert(lines.none? { |line| line.include?("\e") }, 'no raw control byte reaches the log')
    end
  end

  private

  def entries(tag, count)
    Array.new(count) do |index|
      image = "image #{tag}#{index + 1}"
      ["#{Digest::SHA256.hexdigest(image)}\n", image]
    end
  end

  def server(queue) = Erx::NetbootServer::Server.new(queue: queue, prefix: PREFIX, log: ->(_) {})

  def request(method, path) = Erx::Web::Http::Request.new(method: method, path: path, query: nil, headers: {}, rest: '')

  def answer(request, server: @server, client: BOARD, out: Out.new)
    server.answer(request, client: client, out: out)
    out
  rescue Errno::EPIPE
    out
  end

  def get(name, method: 'GET', **options) = answer(request(method, "/#{PREFIX}/#{name}"), **options)

  # One download: the signature's request, then the image's; the image's bytes.
  def download
    get('boot.sig')
    get('boot.img').body
  end

  # The status and body the loopback server answers to request line line.
  def fetch(port, line)
    socket = TCPSocket.new('127.0.0.1', port)
    socket.write("#{line}\r\nHost: 127.0.0.1\r\n\r\n")
    response = socket.read.b
    head, body = response.split("\r\n\r\n", 2)
    [head[%r{\AHTTP/1\.1 (\d+)}, 1].to_i, body.to_s]
  ensure
    socket&.close
  end
end
