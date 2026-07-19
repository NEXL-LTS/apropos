require "json"
require "./filesystem"

module Apropos
  # Per-session dedup store: the set of rule-file paths already
  # injected during a Claude Code session, so a rule is delivered at most once
  # per session. Persisted as JSON at `.cache/apropos/sessions/<session_id>.json`
  # with an `updated_at` stamp used to prune stale files opportunistically.
  #
  # All disk access goes through an injected `Filesystem`; the clock is injected
  # too (`now`), so persistence and pruning are unit-testable without real time.
  class SessionState
    DIR = Path[".cache", "apropos", "sessions"]

    # Session files untouched for longer than this are pruned on any hook run.
    MAX_AGE = 7.days

    # The on-disk shape. Kept minimal so a lost concurrent update costs at most
    # one duplicate injection.
    struct Document
      include JSON::Serializable

      @[JSON::Field(key: "updated_at")]
      getter updated_at : Int64
      getter injected : Array(String)

      def initialize(@updated_at : Int64, @injected : Array(String))
      end
    end

    getter injected : Set(String)

    def initialize(@injected : Set(String) = Set(String).new)
    end

    # Load the state for `session_id`. A missing or unparseable file is treated
    # as an empty state (fail open). A nil `session_id` means dedup is
    # unavailable, so every rule is considered new.
    def self.load(repo_root : Path, fs : Filesystem, session_id : String?) : SessionState
      return new unless session_id
      json = fs.read?(file_for(repo_root, session_id).to_s)
      return new unless json
      new(Document.from_json(json).injected.to_set)
    rescue JSON::ParseException
      new
    end

    # Delete session files whose `updated_at` is older than MAX_AGE. Best-effort
    # and opportunistic: a corrupt or unreadable file is skipped, never fatal.
    def self.prune(repo_root : Path, fs : Filesystem, now : Time) : Nil
      cutoff = (now - MAX_AGE).to_unix
      fs.glob(repo_root.join(DIR), "*.json").each do |file|
        json = fs.read?(file)
        next unless json
        document = parse(json)
        next unless document
        fs.remove(file) if document.updated_at < cutoff
      end
    end

    private def self.parse(json : String) : Document?
      Document.from_json(json)
    rescue JSON::ParseException
      nil
    end

    # Has `rule_path` already been injected this session?
    def injected?(rule_path : String) : Bool
      @injected.includes?(rule_path)
    end

    # Record `rule_path` as injected.
    def add(rule_path : String) : Nil
      @injected << rule_path
    end

    # Persist the state for `session_id`, stamping `now`. The injected set is
    # sorted so the file is byte-stable for a given set (aids debugging and
    # avoids spurious churn). A nil `session_id` is a no-op.
    def save(repo_root : Path, fs : Filesystem, session_id : String?, now : Time) : Nil
      return unless session_id
      document = Document.new(now.to_unix, @injected.to_a.sort)
      fs.write(SessionState.file_for(repo_root, session_id).to_s, "#{document.to_json}\n")
    end

    def self.file_for(repo_root : Path, session_id : String) : Path
      repo_root.join(DIR, "#{session_id}.json")
    end
  end
end
