require "json"
require "semantic_version"
require "./conventions"
require "./index"
require "./environment"
require "./filesystem"

module Apropos
  # `apropos doctor`: check the environment so a user can tell *why*
  # hooks aren't firing. It inspects the settings wiring, whether `apropos` and a
  # new-enough Claude Code are on PATH, index freshness, and cache writability.
  # All host access is injected (a `Filesystem` and an `Environment`) so every
  # branch is unit-testable. Exit 1 if any check fails, else 0.
  module Doctor
    extend self

    INDEX_RELATIVE           = Path[".cache", "apropos", "index.json"]
    SETTINGS_RELATIVE        = Path[".claude", "settings.json"]
    OPENCODE_PLUGIN_RELATIVE = Path[".opencode", "plugins", "apropos.js"]
    GEMINI_SETTINGS_RELATIVE = Path[".gemini", "settings.json"]
    PROBE_RELATIVE           = Path[".cache", "apropos", ".doctor-probe"]

    APROPOS_HOOK_PREFIX = "apropos hook"

    # The minimum Claude Code version known to support PreToolUse
    # `additionalContext`. Older CLIs degrade Layer 2 to PostToolUse.
    MIN_CLAUDE_VERSION = "1.0.0"

    # One environment check: `:ok`, `:warn` (advisory), or `:fail` (exit 1).
    record Check, status : Symbol, name : String, detail : String

    def run(repo_root : Path, fs : Filesystem, env : Environment, stdout : IO, stderr : IO) : Int32
      checks = [
        settings_check(repo_root, fs),
        apropos_check(env),
        claude_check(env),
        opencode_check(repo_root, fs, env),
        gemini_check(repo_root, fs, env),
        index_check(repo_root, fs),
        cache_check(repo_root, fs),
      ]
      report(checks, stdout)
    end

    private def settings_check(repo_root : Path, fs : Filesystem) : Check
      content = fs.read?(repo_root.join(SETTINGS_RELATIVE).to_s)
      return Check.new(:fail, "hooks", ".claude/settings.json not found; run `apropos init`") unless content

      events = apropos_events(content)
      return Check.new(:warn, "hooks", ".claude/settings.json is not valid JSON") if events.nil?

      pre = events.includes?("PreToolUse")
      post = events.includes?("PostToolUse")
      if pre && post
        Check.new(:ok, "hooks", "PreToolUse and PostToolUse call apropos")
      elsif pre || post
        Check.new(:warn, "hooks", "only #{pre ? "PreToolUse" : "PostToolUse"} calls apropos; run `apropos init`")
      else
        Check.new(:fail, "hooks", "no apropos hooks wired; run `apropos init`")
      end
    end

    # Which events have a group whose command invokes `apropos hook`. Returns nil
    # when the settings file is not parseable JSON.
    private def apropos_events(content : String) : Set(String)?
      parsed =
        begin
          JSON.parse(content)
        rescue JSON::ParseException
          return nil
        end
      hooks = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?)
      events = Set(String).new
      return events unless hooks
      hooks.each do |event, groups|
        array = groups.as_a?
        next unless array
        events << event if array.any? { |group| apropos_group?(group) }
      end
      events
    end

    private def apropos_group?(group : JSON::Any) : Bool
      hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
      return false unless hooks
      hooks.any? do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        !command.nil? && command.starts_with?(APROPOS_HOOK_PREFIX)
      end
    end

    private def apropos_check(env : Environment) : Check
      if path = env.which("apropos")
        Check.new(:ok, "apropos", "on PATH at #{path}")
      else
        Check.new(:warn, "apropos", "not found on PATH; hooks invoke `apropos`")
      end
    end

    private def claude_check(env : Environment) : Check
      return Check.new(:ok, "claude", "not on PATH; skipped PreToolUse capability check") unless env.which("claude")

      output = env.run_capture("claude", ["--version"])
      return Check.new(:warn, "claude", "could not run `claude --version`") unless output

      version = extract_version(output)
      return Check.new(:warn, "claude", "could not parse a version from #{output.strip.inspect}") unless version

      if version >= min_version
        Check.new(:ok, "claude", "#{version} supports PreToolUse additionalContext")
      else
        Check.new(:warn, "claude", "#{version} may lack PreToolUse additionalContext (need >= #{MIN_CLAUDE_VERSION})")
      end
    end

    private def extract_version(output : String) : SemanticVersion?
      match = output.match(/(\d+\.\d+\.\d+)/)
      return nil unless match
      SemanticVersion.parse(match[1])
    end

    private def min_version : SemanticVersion
      SemanticVersion.parse(MIN_CLAUDE_VERSION)
    end

    # Check for the OpenCode binary and the generated plugin that bridges
    # `apropos hook` into OpenCode's plugin event system. Advisory only: never
    # fails, so a Claude-only repo is not penalised.
    private def opencode_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
      unless env.which("opencode")
        return Check.new(:ok, "opencode", "not on PATH; skipped plugin check")
      end
      plugin = repo_root.join(OPENCODE_PLUGIN_RELATIVE).to_s
      if fs.exists?(plugin)
        Check.new(:ok, "opencode", "plugin wired")
      else
        Check.new(:warn, "opencode", "plugin absent; run `apropos init --tool opencode`")
      end
    end

    # Check for the Gemini CLI binary and that its AfterTool hook (the only
    # event whose output schema supports injecting context) calls both
    # `apropos hook pre` and `apropos hook post`. Advisory only: never fails,
    # so a Gemini-less repo is not penalised.
    private def gemini_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
      unless env.which("gemini")
        return Check.new(:ok, "gemini", "not on PATH; skipped hook check")
      end
      content = fs.read?(repo_root.join(GEMINI_SETTINGS_RELATIVE).to_s)
      return Check.new(:warn, "gemini", ".gemini/settings.json absent; run `apropos init --tool gemini`") unless content

      wired = gemini_wired?(content)
      return Check.new(:warn, "gemini", ".gemini/settings.json is not valid JSON") if wired.nil?

      if wired
        Check.new(:ok, "gemini", "AfterTool hook wired")
      else
        Check.new(:warn, "gemini", "AfterTool hook absent; run `apropos init --tool gemini`")
      end
    end

    # Whether any single `AfterTool` group calls both `apropos hook pre` and
    # `apropos hook post`. Returns nil when the settings file is not
    # parseable JSON.
    #
    # Checked per group, not flattened across all of them: Gemini can have a
    # second, read-only group carrying only `apropos hook pre` (see
    # `Init#ensure_gemini_read_group`), so a flattened union of commands
    # across every group could see both commands present overall while the
    # write/edit group itself is missing one — e.g. `pre` only in the read
    # group and `post` in the write group, which is a miswire (Layer 2 never
    # fires on an edit) that a flattened check can't tell apart from being
    # fully wired. Same principle as docs/conventions/settings-merge-identity.md.
    private def gemini_wired?(content : String) : Bool?
      parsed =
        begin
          JSON.parse(content)
        rescue JSON::ParseException
          return nil
        end
      groups = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?).try(&.["AfterTool"]?).try(&.as_a?)
      return false unless groups
      groups.compact_map(&.as_h?).any? do |group|
        commands = (group["hooks"]?.try(&.as_a?) || [] of JSON::Any)
          .compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
        commands.includes?("apropos hook pre") && commands.includes?("apropos hook post")
      end
    end

    private def index_check(repo_root : Path, fs : Filesystem) : Check
      json = fs.read?(repo_root.join(INDEX_RELATIVE).to_s)
      return Check.new(:warn, "index", "not built; run `apropos generate`") unless json

      index = Index.load(json)
      return Check.new(:warn, "index", "unreadable; run `apropos generate`") unless index

      conventions =
        begin
          Conventions.walk(repo_root, fs)
        rescue Apropos::Error
          return Check.new(:warn, "index", "cannot evaluate freshness; run `apropos lint`")
        end

      if index.covers?(conventions)
        Check.new(:ok, "index", "fresh")
      else
        Check.new(:warn, "index", "stale; run `apropos generate`")
      end
    end

    private def cache_check(repo_root : Path, fs : Filesystem) : Check
      probe = repo_root.join(PROBE_RELATIVE).to_s
      fs.write(probe, "ok")
      fs.remove(probe)
      Check.new(:ok, "cache", ".cache/apropos is writable")
    rescue
      Check.new(:fail, "cache", ".cache/apropos is not writable")
    end

    private def report(checks : Array(Check), stdout : IO) : Int32
      checks.each { |check| stdout.puts "#{marker(check.status)}  #{check.name}: #{check.detail}" }
      failures = checks.count { |check| check.status == :fail }
      warnings = checks.count { |check| check.status == :warn }
      stdout.puts "doctor: #{failures} failure(s), #{warnings} warning(s)"
      failures > 0 ? 1 : 0
    end

    private def marker(status : Symbol) : String
      case status
      when :ok
        "ok  "
      when :warn
        "warn"
      else
        "fail"
      end
    end
  end
end
