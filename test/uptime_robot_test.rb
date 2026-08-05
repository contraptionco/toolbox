require_relative 'test_helper'
require_relative '../lib/uptime_robot'

class UptimeRobotTest < Minitest::Test
  Response = Struct.new(:code)

  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def request(_request)
      Response.new('200')
    end
  end

  def test_http_request_has_timeouts
    http = FakeHttp.new

    capture_output do
      Core::OnePassword.stub(:get_item, 'https://example.com/heartbeat') do
        Net::HTTP.stub(:new, http) do
          assert Core::UptimeRobot.report
        end
      end
    end

    assert_equal Core::UptimeRobot::OPEN_TIMEOUT, http.open_timeout
    assert_equal Core::UptimeRobot::READ_TIMEOUT, http.read_timeout
    assert_equal Core::UptimeRobot::WRITE_TIMEOUT, http.write_timeout
  end
end
