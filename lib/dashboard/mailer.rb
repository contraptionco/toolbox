require 'net/smtp'
require 'openssl'
require 'cgi'
require 'securerandom'
require 'uri'
require 'time'
require 'base64'

module Dashboard
  class Mailer
    class DeliveryError < StandardError; end

    def initialize(host:, user:, password:, origin:, port: 587, from: 'Toolbox <toolbox@ilic.nyc>', require_tls: true)
      @host, @user, @password, @origin = host.to_s, user.to_s, password.to_s, origin.to_s
      @port, @from, @require_tls = Integer(port), from.to_s, require_tls
      raise ArgumentError, 'Invalid sender' if @from.match?(/[\r\n]/) || !@from.match?(/(?:<)?[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9.-]+(?:>)?\z/)
      raise ArgumentError, 'SMTP TLS is required' unless @require_tls || %w[localhost 127.0.0.1 ::1].include?(@host)
    end

    def configured?
      !@host.empty? && (!@user.empty? && !@password.empty? || %w[localhost 127.0.0.1 ::1].include?(@host))
    end

    def send_code(email:, code:)
      raise DeliveryError, 'Email delivery is unavailable' unless configured? && email == 'philip@ilic.nyc' && code.match?(/\A\d{6}\z/)
      smtp = Net::SMTP.new(@host, @port)
      smtp.open_timeout = 10
      smtp.read_timeout = 15
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
      @port == 465 ? smtp.enable_tls(context) : smtp.enable_starttls(context) if @require_tls
      sender = @from[/<([^>]+)>/, 1] || @from
      smtp.start(URI(@origin).host, @user.empty? ? nil : @user, @password.empty? ? nil : @password, :login) do |connection|
        connection.send_message(message(email: email, code: code), sender, email)
      end
      true
    rescue StandardError
      # Never pass provider diagnostics, SMTP credentials, or the code into logs.
      raise DeliveryError, 'Email delivery is unavailable'
    end

    def message(email:, code:)
      subject = 'Your Toolbox sign-in code'
      notice = 'This code expires in 10 minutes and can only be used once. If you did not request this email, you can ignore it.'
      text = "Your Toolbox sign-in code is #{code}.\n\n#{notice}\n"
      origin = CGI.escapeHTML(@origin)
      html = <<~HTML
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark"><style>
        @font-face{font-family:Sohne;src:url('https://fonts.philipithomas.com/klim/soehne-buch.woff2') format('woff2');font-weight:400;font-display:swap}
        @font-face{font-family:'Sohne Mono';src:url('https://fonts.philipithomas.com/klim/soehne-mono-buch.woff2') format('woff2');font-weight:400;font-display:swap}
        @font-face{font-family:Sohne;src:url('https://fonts.philipithomas.com/klim/soehne-buch.woff2') format('woff2');font-weight:400}
        @font-face{font-family:'Sohne Mono';src:url('https://fonts.philipithomas.com/klim/soehne-mono-buch.woff2') format('woff2');font-weight:400}
        @media(max-width:600px){.outer{padding:24px 12px!important}.content{padding:28px 24px!important}}
        @media(prefers-color-scheme:dark){body,.outer{background:#121110!important}.card{background:#1C1A17!important}.card p{color:#D7D3CC!important}.code{color:#ECE9E4!important}.muted{color:#A8A49D!important}}
        </style></head><body style="margin:0;background:#F5F3F0;font-family:Sohne,Arial,Helvetica,sans-serif"><div style="display:none;max-height:0;overflow:hidden">Your sign-in code expires in 10 minutes.</div>
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td class="outer" align="center" style="padding:40px 20px;background:#F5F3F0"><table role="presentation" class="card" width="100%" cellspacing="0" cellpadding="0" style="max-width:540px;background:#fff"><tr><td class="content" style="padding:40px">
        <p style="margin:0 0 36px"><a href="#{origin}"><img src="#{origin}/icons/logo.svg" width="144" alt="Toolbox" style="border:0;max-width:100%;background:#F5F3F0;padding:8px"></a></p>
        <p style="margin:0 0 24px;font-size:15px;line-height:1.6;color:#3B3834">Your sign-in code is:</p>
        <p class="code" style="margin:0 0 32px;font-family:'Sohne Mono',Consolas,monospace;font-size:32px;line-height:1.4;font-weight:600;letter-spacing:0.2em;color:#111110">#{CGI.escapeHTML(code)}</p>
        <p class="muted" style="margin:0;font-size:13px;line-height:1.6;color:#7E7A73">#{notice}</p>
        </td></tr></table></td></tr></table></body></html>
      HTML
      boundary = "toolbox-#{SecureRandom.hex(16)}"
      parts = [["text/plain", text], ["text/html", html]].map do |type, content|
        "--#{boundary}\r\nContent-Type: #{type}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n#{Base64.encode64(content).gsub("\n", "\r\n")}"
      end.join("\r\n")
      ["From: #{@from}", "To: #{email}", "Subject: #{subject}", "Date: #{Time.now.rfc2822}",
       "Message-ID: <#{SecureRandom.hex(16)}@#{URI(@origin).host}>", 'MIME-Version: 1.0',
       "Content-Type: multipart/alternative; boundary=\"#{boundary}\"", '', parts, "--#{boundary}--", ''].join("\r\n")
    end
  end
end
