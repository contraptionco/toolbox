require_relative 'test_helper'
require_relative '../lib/dashboard/http_body'
require 'webrick'
require 'socket'
require 'timeout'

class DashboardHTTPBodyTest < Minitest::Test
  class StreamingRequest
    attr_reader :reads
    def initialize(chunks, length = nil)
      @chunks, @length, @reads = chunks, length, 0
    end
    def [](name) = name == 'content-length' ? @length : nil
    def body
      @chunks.each do |chunk|
        @reads += 1
        yield chunk
      end
      nil
    end
  end

  class BufferedRequest
    def initialize(body) = @body = body
    def [](_name) = nil
    def body = @body
  end

  def test_declared_oversized_or_malformed_bodies_are_rejected_before_reading
    ['11', '-1', '4x', '3,3', ''].each do |length|
      request = StreamingRequest.new(['private bytes'], length)
      assert_raises(Dashboard::HTTPBody::TooLarge) { Dashboard::HTTPBody.read(request, limit: 10) }
      assert_equal 0, request.reads
    end
  end

  def test_chunked_overflow_stops_before_reading_the_rest
    request = StreamingRequest.new(['abcd', 'efgh', 'ijk', 'never read'])
    assert_raises(Dashboard::HTTPBody::TooLarge) { Dashboard::HTTPBody.read(request, limit: 10) }
    assert_equal 3, request.reads
  end

  def test_a_small_declared_length_cannot_bypass_actual_byte_limit
    request = StreamingRequest.new(['abcdef', 'ghijkl'], '6')
    assert_raises(Dashboard::HTTPBody::TooLarge) { Dashboard::HTTPBody.read(request, limit: 10) }
    assert_equal 2, request.reads
  end

  def test_exact_limit_and_multibyte_payloads_use_bytes
    assert_equal 'abcdefghij', Dashboard::HTTPBody.read(StreamingRequest.new(['abc', 'defghij'], '10'), limit: 10)
    assert_equal 'éé', Dashboard::HTTPBody.read(StreamingRequest.new(['é', 'é']), limit: 4)
    assert_raises(Dashboard::HTTPBody::TooLarge) { Dashboard::HTTPBody.read(StreamingRequest.new(['éé', 'é']), limit: 4) }
  end

  def test_fixture_fallback_is_also_bounded_and_handles_empty_bodies
    assert_equal 'fixture', Dashboard::HTTPBody.read(BufferedRequest.new('fixture'), limit: 7)
    assert_raises(Dashboard::HTTPBody::TooLarge) { Dashboard::HTTPBody.read(BufferedRequest.new('oversized'), limit: 4) }
    assert_equal '', Dashboard::HTTPBody.read(BufferedRequest.new(nil), limit: 4)
    assert_equal '', Dashboard::HTTPBody.read(StreamingRequest.new([]), limit: 4)
  end
  def test_reject_disables_keep_alive_and_marks_connection_closed
    response = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    response.keep_alive = true
    Dashboard::HTTPBody.reject(response)
    assert_equal false, response.keep_alive?
    assert_equal 'close', response['Connection']
    headers = {}
    Dashboard::HTTPBody.reject(headers)
    assert_equal 'close', headers['Connection']
  end

  def test_real_webrick_rejects_without_draining_declared_or_chunked_remainder
    server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
      RequestTimeout: 10, AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
    server.mount_proc('/') do |request, response|
      Dashboard::HTTPBody.read(request, limit: 8)
      response.body = 'accepted'
    rescue Dashboard::HTTPBody::TooLarge
      Dashboard::HTTPBody.reject(response)
      response.status, response.body = 413, 'too large'
    end
    thread = Thread.new { server.start }
    port = server.listeners.first.addr[1]
    requests = [
      "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\nConnection: keep-alive\r\n\r\n",
      "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n10\r\nabcdefghijklmnop"
    ]
    socket = nil
    requests.each do |wire|
      socket = TCPSocket.new('127.0.0.1', port)
      socket.write(wire)
      # The client deliberately never sends the remaining declared body or the
      # final chunk. A response must arrive before WEBrick's 10-second timeout.
      response = Timeout.timeout(2) { socket.read }
      assert_match(/\AHTTP\/1\.1 413 /, response)
      assert_match(/\r\nConnection: close\r\n/i, response)
      assert_includes response, 'too large'
      socket.close
    end
  ensure
    socket&.close unless socket&.closed?
    server&.shutdown
    thread&.join(2)
  end

end
