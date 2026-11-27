require 'sqlite3'
require 'fileutils'
require 'thread'

module Dashboard
  # A single private SQLite file owns auth state. Callers own transaction scopes.
  class AuthStore
    def initialize(path:)
      @mutex = Mutex.new
      if path != ':memory:'
        path = File.expand_path(path)
        parent = File.dirname(path)
        FileUtils.mkdir_p(parent, mode: 0o700)
        raise ArgumentError, 'Unsafe auth directory' if File.symlink?(parent) || File.stat(parent).uid != Process.uid
        File.chmod(0o700, parent)
        raise ArgumentError, 'Unsafe auth database' if File.symlink?(path)
        unless File.exist?(path)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
        end
        raise ArgumentError, 'Unsafe auth database' unless File.file?(path) && File.stat(path).uid == Process.uid
        File.chmod(0o600, path)
      end
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.busy_timeout = 5000
      @db.execute('PRAGMA foreign_keys = ON')
      @db.execute('PRAGMA journal_mode = DELETE')
      @db.execute('PRAGMA synchronous = FULL')
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS auth_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS auth_sessions (
          token_hash TEXT PRIMARY KEY, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS auth_login (
          owner TEXT PRIMARY KEY, code_hash TEXT NOT NULL, browser_hash TEXT NOT NULL,
          expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS auth_limits (
          key TEXT PRIMARY KEY, count INTEGER NOT NULL, expires_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS auth_challenges (
          browser_hash TEXT NOT NULL, purpose TEXT NOT NULL, challenge TEXT NOT NULL,
          session_id TEXT, expires_at INTEGER NOT NULL, PRIMARY KEY(browser_hash, purpose)
        );
        CREATE TABLE IF NOT EXISTS auth_passkeys (
          id TEXT PRIMARY KEY, public_key TEXT NOT NULL, sign_count INTEGER NOT NULL,
          name TEXT NOT NULL, transports TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL,
          last_used_at INTEGER
        );
      SQL
    end

    def with_db
      @mutex.synchronize { yield @db }
    end

    def close
      @mutex.synchronize { @db.close }
    end
  end
end
