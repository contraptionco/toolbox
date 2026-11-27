module Dashboard
  module HTTPBody
    class TooLarge < StandardError; end

    # WEBrick drains unread bodies before sending a keep-alive response. Close
    # rejected requests so an oversized stream cannot hold the worker indefinitely.
    def self.reject(response)
      response.keep_alive = false if response.respond_to?(:keep_alive=)
      response['Connection'] = 'close'
    end

    def self.read(request, limit:)
      length = request['content-length']
      raise TooLarge if length && (!length.match?(/\A\d+\z/) || length.to_i > limit)
      content = +''
      # WEBrick streams chunks when a block is supplied instead of buffering an
      # unbounded body. Simple request fixtures may return an already-read body.
      result = request.body do |chunk|
        raise TooLarge if content.bytesize + chunk.bytesize > limit
        content << chunk
      end
      content = result.to_s if content.empty? && result.is_a?(String)
      raise TooLarge if content.bytesize > limit
      content
    end
  end
end
