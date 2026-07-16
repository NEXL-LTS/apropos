require "json"
require "semantic_version"
require "./conventions"
require "./index"
require "./environment"
require "./filesystem"

module Muninn
  # `muninn doctor` (PRD §5.8): check the environment so a user can tell *why*
  # hooks aren't firing. It inspects the settings wiring, whether `muninn` and a
  # new-enough Claude Code are on PATH, index freshness, and cache writability.
  # All host access is injected (a `Filesystem` and an `Environment`) so every
  # branch is unit-testable. Exit 1 if any check fails, else 0.
  module Doctor
    extend self

    INDEX_RELATIVE    = Path[".cache", "muninn", "index.json"]
    SETTINGS_RELATIVE = Path[".claude", "settings.json"]
    PROBE_RELATIVE    = Path[".cache", "muninn", ".doctor-probe"]

    MUNINN_HOOK_PREFIX = "muninn hook"

    # The minimum Claude Code version known to support PreToolUse
    # `additionalContext` (PRD §5.4). Older CLIs degrade Layer 2 to PostToolUse.
    MIN_CLAUDE_VERSION = "1.0.0"

    # One environment check: `:ok`, `:warn` (advisory), or `:fail` (exit 1).
    record Check, status : Symbol, name : String, detail : String

    def run(repo_root : Path, fs : Filesystem, env : Environment, stdout : IO, stderr : IO) : Int32
      checks = [
        settings_check(repo_root, fs),
        muninn_check(env),
        claude_check(env),
        index_check(repo_root, fs),
        cache_check(repo_root, fs),
      ]
      report(checks, stdout)
    end

    private def settings_check(repo_root : Path, fs : Filesystem) : Check
      content = fs.read?(repo_root.join(SETTINGS_RELATIVE).to_s)
      return Check.new(:fail, "hooks", ".claude/settings.json not found; run `muninn init`") unless content

      events = muninn_events(content)
      return Check.new(:warn, "hooks", ".claude/settings.json is not valid JSON") if events.nil?

      pre = events.includes?("PreToolUse")
      post = events.includes?("PostToolUse")
      if pre && post
        Check.new(:ok, "hooks", "PreToolUse and PostToolUse call muninn")
      elsif pre || post
        Check.new(:warn, "hooks", "only #{pre ? "PreToolUse" : "PostToolUse"} calls muninn; run `muninn init`")
      else
        Check.new(:fail, "hooks", "no muninn hooks wired; run `muninn init`")
      end
    end

    # Which events have a group whose command invokes `muninn hook`. Returns nil
    # when the settings file is not parseable JSON.
    private def muninn_events(content : String) : Set(String)?
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
        events << event if array.any? { |group| muninn_group?(group) }
      end
      events
    end

    private def muninn_group?(group : JSON::Any) : Bool
      hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
      return false unless hooks
      hooks.any? do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        !command.nil? && command.starts_with?(MUNINN_HOOK_PREFIX)
      end
    end

    private def muninn_check(env : Environment) : Check
      if path = env.which("muninn")
        Check.new(:ok, "muninn", "on PATH at #{path}")
      else
        Check.new(:warn, "muninn", "not found on PATH; hooks invoke `muninn`")
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

    private def index_check(repo_root : Path, fs : Filesystem) : Check
      json = fs.read?(repo_root.join(INDEX_RELATIVE).to_s)
      return Check.new(:warn, "index", "not built; run `muninn generate`") unless json

      index = Index.load(json)
      return Check.new(:warn, "index", "unreadable; run `muninn generate`") unless index

      conventions =
        begin
          Conventions.walk(repo_root, fs)
        rescue Muninn::Error
          return Check.new(:warn, "index", "cannot evaluate freshness; run `muninn lint`")
        end

      if index.covers?(conventions)
        Check.new(:ok, "index", "fresh")
      else
        Check.new(:warn, "index", "stale; run `muninn generate`")
      end
    end

    private def cache_check(repo_root : Path, fs : Filesystem) : Check
      probe = repo_root.join(PROBE_RELATIVE).to_s
      fs.write(probe, "ok")
      fs.remove(probe)
      Check.new(:ok, "cache", ".cache/muninn is writable")
    rescue
      Check.new(:fail, "cache", ".cache/muninn is not writable")
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
