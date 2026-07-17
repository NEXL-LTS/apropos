require "json"
require "./frontmatter"
require "./conventions"
require "./index"
require "./matcher"
require "./session_state"
require "./filesystem"
require "./repo_root"
require "./rendering"
require "./hooks/payload"

module Muninn
  # The Claude Code hook runtime. `pre` delivers Layer 2
  # (path-scoped) guidance on PreToolUse; `post` delivers Layer 3
  # (construct-scoped) guidance on PostToolUse. Both read the trigger index (the
  # hot path never parses YAML), match against it, dedup per session,
  # render the matched rule bodies under a character cap, and emit the
  # `additionalContext` envelope.
  #
  # Everything here fails **open**: any internal error exits 0 and
  # emits nothing, so a conventions tool can never block or break an edit. All
  # I/O is injected (filesystem, stdin/stdout IO, clock) so every path is
  # unit-testable.
  module Hook
    extend self

    INDEX_RELATIVE = Path[".cache", "muninn", "index.json"]
    LOG_RELATIVE   = Path[".cache", "muninn", "log"]

    # PreToolUse handler: match the target *path* against Layer 2 rules and
    # inject them before the write happens.
    def pre(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
            override_root : String? = nil, verbose : Bool = false) : Int32
      deliver(:pre, io_in, stdout, fs, now, override_root, verbose)
    end

    # PostToolUse handler: match the *written content* against Layer 3 rules
    # (honoring `paths:` AND-scoping) and inject them after the write.
    def post(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
             override_root : String? = nil, verbose : Bool = false) : Int32
      deliver(:post, io_in, stdout, fs, now, override_root, verbose)
    end

    private def deliver(event : Symbol, io_in : IO, stdout : IO, fs : Filesystem,
                        now : Time, override_root : String?, verbose : Bool) : Int32
      payload = Payload.parse(io_in.gets_to_end)
      root = resolve_root(override_root, payload)
      execute(event, payload, root, stdout, fs, now) if payload && root
      0
    rescue ex
      log_failure(fs, override_root, verbose, ex)
      0
    end

    private def execute(event : Symbol, payload : Payload, root : Path,
                        stdout : IO, fs : Filesystem, now : Time) : Nil
      file_path = payload.file_path
      return unless file_path
      relative = relativize(root, file_path)

      index = load_or_build_index(root, fs)
      matches = matches_for(event, index, payload, root, fs, relative)
      return if matches.empty?

      SessionState.prune(root, fs, now)
      state = SessionState.load(root, fs, payload.session_id)
      fresh = matches.reject { |entry| state.injected?(entry.path) }
      return if fresh.empty?

      context = build_context(root, fs, fresh)
      return if context.empty?

      fresh.each { |entry| state.add(entry.path) }
      state.save(root, fs, payload.session_id, now)
      emit(stdout, event_name(event), context)
    end

    private def matches_for(event : Symbol, index : Index, payload : Payload,
                            root : Path, fs : Filesystem, relative : String) : Array(Index::Entry)
      case event
      when :pre
        match_pre(index, relative)
      else
        match_post(index, payload, root, fs, relative)
      end
    end

    # Layer 2: any path-scoped rule whose glob matches the edited path.
    private def match_pre(index : Index, relative : String) : Array(Index::Entry)
      index.docs.select do |entry|
        entry.layer2? && Matcher.any_path_match?(entry.paths, relative)
      end
    end

    # Layer 3: any content-scoped rule whose regex matches the written content;
    # when the rule also declares `paths`, the path must match too (AND).
    private def match_post(index : Index, payload : Payload, root : Path,
                           fs : Filesystem, relative : String) : Array(Index::Entry)
      content = post_content(payload, root, fs, relative)
      return [] of Index::Entry unless content

      index.docs.select do |entry|
        next false unless entry.layer3?
        next false unless Matcher.any_content_match?(entry.contents, content)
        entry.paths.empty? || Matcher.any_path_match?(entry.paths, relative)
      end
    end

    # The content to match Layer 3 against: the payload's written pieces joined,
    # or — when the payload carries no content field — the file read from disk
    # (the drift-tolerant fallback).
    private def post_content(payload : Payload, root : Path, fs : Filesystem,
                             relative : String) : String?
      pieces = payload.written_contents
      return pieces.join('\n') unless pieces.empty?
      fs.read?(root.join(relative).to_s)
    end

    # Read the index; rebuild it in-memory (and best-effort persist) when it is
    # absent, corrupt, or a stale schema version. Freshness against changed docs
    # is *not* checked here — that would re-walk every doc and blow the warm
    # latency budget; `generate` owns keeping the index current.
    private def load_or_build_index(root : Path, fs : Filesystem) : Index
      json = fs.read?(root.join(INDEX_RELATIVE).to_s)
      if json && (index = Index.load(json))
        return index
      end
      index = Index.build(Conventions.walk(root, fs))
      persist_index(root, fs, index)
      index
    end

    private def persist_index(root : Path, fs : Filesystem, index : Index) : Nil
      fs.write(root.join(INDEX_RELATIVE).to_s, index.to_document)
    rescue
      # Warming the cache is best-effort; delivery continues on the in-memory
      # index even when the cache dir is unwritable.
    end

    # Read each matched rule's body (frontmatter stripped) and render them under
    # `Convention (path):` headers, applying the shared cap strategy.
    private def build_context(root : Path, fs : Filesystem, entries : Array(Index::Entry)) : String
      docs = entries.compact_map do |entry|
        text = fs.read?(root.join(entry.path).to_s)
        next unless text
        _, body = Frontmatter.split(text)
        {entry.path, body.strip}
      end
      Rendering.context(docs)
    end

    private def emit(stdout : IO, event_name : String, context : String) : Nil
      JSON.build(stdout) do |json|
        json.object do
          json.field "hookSpecificOutput" do
            json.object do
              json.field "hookEventName", event_name
              json.field "additionalContext", context
            end
          end
        end
      end
      stdout.puts
    end

    private def event_name(event : Symbol) : String
      event == :pre ? "PreToolUse" : "PostToolUse"
    end

    private def resolve_root(override_root : String?, payload : Payload?) : Path?
      return Path[override_root] if override_root
      start = payload.try(&.cwd) || Dir.current
      Muninn.find_repo_root(Path[start])
    end

    private def relativize(root : Path, file_path : String) : String
      path = Path[file_path]
      path.absolute? ? path.relative_to(root).to_posix.to_s : path.to_posix.to_s
    end

    # Best-effort `--verbose` diagnostics. Silent unless verbose, and
    # never raises — it is on the fail-open path.
    private def log_failure(fs : Filesystem, override_root : String?, verbose : Bool, ex : Exception) : Nil
      return unless verbose
      dir = override_root ? Path[override_root] : Path[Dir.current]
      fs.append(dir.join(LOG_RELATIVE).to_s, "muninn hook: #{ex.message}\n")
    rescue
      # Logging must never break the fail-open guarantee.
    end
  end
end
