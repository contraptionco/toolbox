# Logs are operational diagnostics, not a way to inspect request payloads or
# credentials. Redaction is deliberately conservative and remains best effort.
module Dashboard
  module Redactor
    REDACTED = '[redacted]'.freeze
    SENSITIVE_LINE = /(?:authorization|\bcookies?\b|set-cookie|\bparameters\s*:|\benv(?:ironment)?\b\s*[:={]|\b[a-z0-9_-]*(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|access[_-]?key|session[_-]?id|database[_-]?url|connection[_-]?string|client[_-]?secret)[a-z0-9_-]*\b\s*["']?\s*[:=]|OP_SERVICE_ACCOUNT_TOKEN|BEGIN [A-Z ]*PRIVATE KEY|\bop\s+(?:read|item|get|signin)\b)/i
    TOKEN = /\b(?:eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?|(?:sk|ghp|gho|github_pat|ops|opst|xox[baprs])[-_][A-Za-z0-9_-]+|AKIA[A-Z0-9]{16}|[A-Za-z0-9_+\/-]{40,}={0,2})\b/

    def self.line(value)
      text = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�')
                  .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, '').gsub(/[\x00-\x08\x0B-\x1F\x7F]/, '')
      return '[sensitive log line omitted]' if text.match?(SENSITIVE_LINE)

      text = text.gsub(%r{\b[a-z][a-z0-9+.-]*://[^\s<>"']+}i) do |url|
        url.gsub(%r{(?<=://)[^/\s]*@}, "#{REDACTED}@")
           .sub(/[?#].*\z/, '?[redacted]')
      end
      text = text.gsub(/\b[A-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+\b/i, '[email redacted]')
      text = text.gsub(/\b(?:Bearer|Basic)\s+\S+/i, REDACTED).gsub(TOKEN, REDACTED)
      text.length > 2048 ? "#{text[0, 2048]} [line truncated]" : text
    end
  end
end
