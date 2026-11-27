require 'webrick'

module Dashboard
  # ProcHandler handles only GET/HEAD/POST/PUT and intercepts OPTIONS. Delegate
  # all verbs so OAuth/MCP preflight and the app's method guards actually run.
  class HTTPHandler < WEBrick::HTTPServlet::AbstractServlet
    def initialize(server, app)
      super(server)
      @app = app
    end

    def service(request, response)
      @app.call(request, response)
    end
  end
end
