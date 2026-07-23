require "json"
require "./errors"
require "./filesystem"
require "./environment"
require "./config"

module AgentApropos
  # `agent-apropos init`: bootstrap the convention structure into a repo.
  # Idempotent — safe to re-run; a scaffold file is written only when absent
  # unless `--force` is given, and the `.claude/settings.json` and `.gitignore`
  # merges are additive (foreign keys and other hooks are preserved). `--dry-run`
  # prints what would change and writes nothing.
  #
  # Per-tool hook wiring (Claude Code's `.claude/settings.json`, OpenCode's
  # generated plugin, Gemini CLI's `.gemini/settings.json`, GitHub Copilot
  # CLI's `.github/hooks/*.json`) is tool-agnostic: pass `--tool claude` /
  # `--tool opencode` / `--tool gemini` / `--tool copilot` (repeatable) to
  # wire specific agents explicitly, or omit `--tool` entirely to auto-detect
  # by probing PATH for each supported agent. This keeps init easy to extend as
  # more agents (Codex, ...) land.
  #
  # Gemini CLI's hook system has no pre-edit context-injection event (its
  # `BeforeTool` output schema only supports overriding tool arguments or
  # blocking the call — see `merge_gemini_settings`), so both Layer 2 and
  # Layer 3 are wired onto its `AfterTool` event. Layer 2 still fires, just
  # after the edit instead of before it — the same timing degradation
  # `doctor.cr` already documents for older Claude Code versions.
  #
  # GitHub Copilot CLI has the identical limitation on its own `preToolUse`
  # event (output schema is `permissionDecision`/`modifiedArgs` only — no
  # context field), so it gets the same treatment onto `postToolUse` — see
  # `scaffold_copilot`.
  #
  # init is an authoring command, so it fails **closed**: a malformed existing
  # `settings.json` is an error, not a silent overwrite.
  module Init
    extend self

    class Error < AgentApropos::Error
    end

    # CLI agents init knows how to wire hooks for. Extend this set as more
    # emitters land (Codex, Cursor CLI, ...).
    KNOWN_TOOLS = Set{"claude", "opencode", "gemini", "copilot"}

    # The context filename agent-apropos points Gemini CLI at, so Layer 1 reads the
    # same root file Claude Code and OpenCode do without needing a symlink.
    GEMINI_CONTEXT_FILENAME = "AGENTS.md"

    # Parsed flags for one `init` invocation. `tools: nil` means auto-detect;
    # a non-nil set (from one or more `--tool`) is used verbatim, ignoring PATH.
    record Options,
      force : Bool = false,
      example : Bool = false,
      claude_symlink : Bool = false,
      dry_run : Bool = false,
      tools : Set(String)? = nil

    # agent-apropos identifies its own settings entries by this command prefix, so a
    # merge never duplicates a group it already installed.
    AGENT_APROPOS_HOOK_PREFIX = "agent-apropos hook"

    CACHE_IGNORE_ENTRY = ".cache/agent-apropos/"

    # Printed once per run to point at the bootstrapping prompt — most repos
    # arrive with docs already scattered across READMEs/wikis/comments, and an
    # agent can sort those into layers faster than a human writing from scratch.
    # A fully-qualified URL, not a relative "README.md#..." — this section
    # lives in *agent-apropos's own* README, not the target repo's, and terminals
    # only auto-hyperlink absolute URLs.
    NEXT_STEPS_HINT = "next     have your agent bootstrap docs/conventions/ from your existing " \
                      "docs — see https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase"

    def run(repo_root : Path, fs : Filesystem, env : Environment, options : Options, stdout : IO, stderr : IO) : Int32
      tools = resolve_tools(env, options.tools)
      report_tools(stdout, options.tools, tools)
      scaffold(repo_root, fs, options, stdout)
      merge_settings(repo_root, fs, options, stdout) if tools.includes?("claude")
      merge_gitignore(repo_root, fs, options, stdout)
      write_examples(repo_root, fs, options, stdout) if options.example
      link_claude(repo_root, fs, options, stdout) if options.claude_symlink
      scaffold_opencode(repo_root, fs, options, stdout) if tools.includes?("opencode")
      merge_gemini_settings(repo_root, fs, options, stdout) if tools.includes?("gemini")
      scaffold_copilot(repo_root, fs, options, stdout) if tools.includes?("copilot")
      stdout.puts NEXT_STEPS_HINT unless options.dry_run
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos init: #{ex.message}"
      1
    end

    # An explicit `--tool` selection is used verbatim (even if the named agent
    # is not actually on PATH — e.g. bootstrapping a repo for a teammate's
    # setup). Otherwise probe PATH for each known agent.
    private def resolve_tools(env : Environment, explicit : Set(String)?) : Set(String)
      return explicit if explicit
      KNOWN_TOOLS.select { |tool| env.which(tool) }.to_set
    end

    # Only narrate auto-detection — an explicit `--tool` selection was the
    # user's own words, so echoing it back adds nothing.
    private def report_tools(stdout : IO, explicit : Set(String)?, detected : Set(String)) : Nil
      return unless explicit.nil?
      if detected.empty?
        stdout.puts "auto     no supported CLI agent found on PATH; pass --tool claude / --tool opencode to wire one explicitly"
      else
        stdout.puts "auto     detected #{detected.to_a.sort.join(", ")}"
      end
    end

    private def scaffold(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      conventions = conventions_relative(repo_root, fs)
      create(repo_root, fs, options, stdout, "#{conventions}/README.md", CONVENTIONS_README)
      create(repo_root, fs, options, stdout, "#{conventions}/workflows/.gitkeep", "")
      create(repo_root, fs, options, stdout, ".claude/skills/.gitkeep", SKILLS_GITKEEP)
      # The root file is the user's own Layer 1 content — never overwrite it, even
      # under --force; only scaffold it when absent.
      create(repo_root, fs, options, stdout, "AGENTS.md", AGENTS_SKELETON, force_allowed: false)
    end

    private def write_examples(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      conventions = conventions_relative(repo_root, fs)
      create(repo_root, fs, options, stdout, "#{conventions}/example-path-rule.md", EXAMPLE_L2)
      create(repo_root, fs, options, stdout, "#{conventions}/example-content-rule.md", EXAMPLE_L3)
      create(repo_root, fs, options, stdout, "#{conventions}/workflows/example-skill.md", EXAMPLE_SKILL)
    end

    # The conventions directory, relative to `repo_root` (with `../` segments
    # when `agent-apropos.yml` points outside it) — `create`'s single relative-path
    # parameter needs this rather than the resolved absolute `Path` `Config`
    # returns, since it both derives the write location (joined back onto
    # `repo_root`) and the printed display string from the same value.
    private def conventions_relative(repo_root : Path, fs : Filesystem) : String
      Config.conventions_dir(repo_root, fs).relative_to(repo_root).to_posix.to_s
    end

    # Write a scaffold file when absent (or when `--force` and `force_allowed`),
    # otherwise report it as already present.
    private def create(repo_root : Path, fs : Filesystem, options : Options, stdout : IO,
                       relative : String, content : String, force_allowed : Bool = true) : Nil
      path = repo_root.join(relative).to_s
      display = Path[relative].to_posix.to_s
      if fs.exists?(path) && !(force_allowed && options.force)
        stdout.puts "exists   #{display}"
        return
      end
      verb = fs.exists?(path) ? "update" : "create"
      apply(fs, options, stdout, path, content, verb, display)
    end

    # Reconcile a merge target: write only when the merged content differs from
    # what is on disk, so re-running is a no-op.
    private def sync(fs : Filesystem, options : Options, stdout : IO,
                     path : String, content : String, existing : String?, display : String) : Nil
      if existing == content
        stdout.puts "current  #{display}"
        return
      end
      apply(fs, options, stdout, path, content, existing.nil? ? "create" : "update", display)
    end

    private def apply(fs : Filesystem, options : Options, stdout : IO,
                      path : String, content : String, verb : String, display : String) : Nil
      if options.dry_run
        stdout.puts "would #{verb} #{display}"
      else
        fs.write(path, content)
        stdout.puts "#{verb}d  #{display}"
      end
    end

    private def merge_settings(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".claude", "settings.json").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, merged_settings(existing), existing, ".claude/settings.json")
    end

    # Merge agent-apropos's PreToolUse/PostToolUse hook groups into an existing (or
    # new) settings object, preserving every other key and hook. `agent-apropos
    # hook pre` is wired onto both "Edit|Write" and "Read" — Layer 2 depends
    # only on the target path, which a read carries exactly like an edit, so
    # the same rule can land as early as the model's first read instead of
    # only once it writes there.
    private def merged_settings(existing : String?) : String
      root = settings_root(existing, ".claude/settings.json")
      hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any

      pre_groups = (hooks["PreToolUse"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
      pre_groups = ensure_commands(pre_groups, "Edit|Write", ["agent-apropos hook pre"], CLAUDE_HOOK_TIMEOUT)
      pre_groups = ensure_commands(pre_groups, "Read", ["agent-apropos hook pre"], CLAUDE_HOOK_TIMEOUT)
      hooks["PreToolUse"] = JSON::Any.new(pre_groups)

      post_groups = (hooks["PostToolUse"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
      post_groups = ensure_commands(post_groups, "Edit|Write", ["agent-apropos hook post"], CLAUDE_HOOK_TIMEOUT)
      hooks["PostToolUse"] = JSON::Any.new(post_groups)

      root["hooks"] = JSON::Any.new(hooks)
      JSON::Any.new(root).to_pretty_json + "\n"
    end

    private def settings_root(existing : String?, label : String) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if existing.nil?
      parsed =
        begin
          JSON.parse(existing)
        rescue ex : JSON::ParseException
          raise Error.new("existing #{label} is not valid JSON: #{ex.message}")
        end
      hash = parsed.as_h?
      raise Error.new("#{label} must be a JSON object") if hash.nil?
      hash.dup
    end

    # Ensure every command in `commands` exists in at least one group with
    # this exact `matcher`, healing (refreshing present commands to the
    # current `hook_command` shape, appending whatever's missing to one of
    # them) when a group already exists, or appending a fresh one carrying
    # all of `commands` when none does.
    #
    # Matcher-keyed, not command-ownership-keyed: `agent-apropos hook pre` is
    # wired onto two matchers here ("Edit|Write" and "Read"), so a search
    # that only asks "does some group already carry this command" can't
    # tell the two groups apart — it would find whichever one the traversal
    # reaches first (order in the JSON array is not guaranteed) and heal
    # that one, potentially leaving the *other* matcher's group never
    # created. Keying on the matcher instead means each call only ever
    # touches the group(s) it's actually about.
    #
    # A given matcher can have more than one group already — e.g. a legacy
    # agent-apropos version (or a hand-edit) put its own command in a separate
    # "Edit|Write" group instead of a foreign hook's — so presence is
    # checked across *every* matching group, not just the first: otherwise
    # healing the foreign hook's group would add a second copy of a command
    # already installed in the other one. Missing commands are appended to
    # only the first matching group.
    private def ensure_commands(groups : Array(JSON::Any), matcher : String,
                                commands : Array(String), timeout : Int64) : Array(JSON::Any)
      matching = groups.each_index.select { |i| group_matcher(groups[i]) == matcher }.to_a
      return groups + [hook_group(matcher, commands, timeout)] if matching.empty?

      groups = groups.dup
      matching.each { |i| groups[i] = refresh_owned_hooks(groups[i], commands, timeout) }

      present = matching.flat_map { |i| present_commands(groups[i]) }
      missing = commands.reject { |command| present.includes?(command) }
      return groups if missing.empty?

      target = matching.first
      groups[target] = append_hooks(groups[target], missing, timeout)
      groups
    end

    private def group_matcher(group : JSON::Any) : String?
      group.as_h?.try(&.["matcher"]?).try(&.as_s?)
    end

    private def present_commands(group : JSON::Any) : Array(String)
      hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?) || [] of JSON::Any
      hooks.compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
    end

    # Refresh every one of *our* commands already in this group to the
    # current `hook_command` shape (so a stale field converges on the next
    # `init` run instead of surviving forever). Foreign hooks (anything not
    # in `commands`) pass through untouched.
    private def refresh_owned_hooks(group : JSON::Any, commands : Array(String), timeout : Int64) : JSON::Any
      hash = group.as_h.dup
      present = hash["hooks"]?.try(&.as_a?) || [] of JSON::Any
      refreshed = present.map do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        command && commands.includes?(command) ? hook_command(command, timeout) : hook
      end
      hash["hooks"] = JSON::Any.new(refreshed)
      JSON::Any.new(hash)
    end

    private def append_hooks(group : JSON::Any, commands : Array(String), timeout : Int64) : JSON::Any
      hash = group.as_h.dup
      present = hash["hooks"]?.try(&.as_a?) || [] of JSON::Any
      hash["hooks"] = JSON::Any.new(present + commands.map { |command| hook_command(command, timeout) })
      JSON::Any.new(hash)
    end

    private def hook_group(matcher : String, commands : Array(String), timeout : Int64) : JSON::Any
      JSON::Any.new({
        "matcher" => JSON::Any.new(matcher),
        "hooks"   => JSON::Any.new(commands.map { |command| hook_command(command, timeout) }),
      })
    end

    private def hook_command(command : String, timeout : Int64) : JSON::Any
      JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new(command),
        "timeout" => JSON::Any.new(timeout),
      })
    end

    # Claude Code's hook `timeout` is seconds.
    CLAUDE_HOOK_TIMEOUT = 10_i64

    # agent-apropos identifies its own settings entries by this command prefix, so a
    # merge never duplicates a group it already installed. Still used by
    # Gemini CLI's own (separate) settings merge below.
    private def agent_apropos_group?(group : JSON::Any) : Bool
      hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
      return false unless hooks
      hooks.any? do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        !command.nil? && command.starts_with?(AGENT_APROPOS_HOOK_PREFIX)
      end
    end

    private def agent_apropos_group(sub : String) : JSON::Any
      hook = JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new("agent-apropos hook #{sub}"),
        "timeout" => JSON::Any.new(10_i64),
      })
      JSON::Any.new({
        "matcher" => JSON::Any.new("Edit|Write"),
        "hooks"   => JSON::Any.new([hook]),
      })
    end

    private def merge_gitignore(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".gitignore").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, merged_gitignore(existing), existing, ".gitignore")
    end

    private def merged_gitignore(existing : String?) : String
      if existing.nil?
        return "# agent-apropos trigger index + session state (regenerated; not committed).\n" \
               "#{CACHE_IGNORE_ENTRY}\n"
      end
      return existing if existing.each_line.any? { |line| line.strip == CACHE_IGNORE_ENTRY }
      separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
      "#{existing}#{separator}#{CACHE_IGNORE_ENTRY}\n"
    end

    # Write (or update) the OpenCode Bun plugin that bridges `agent-apropos hook pre`
    # into OpenCode's `tool.execute.before` event (Layer 2) and `agent-apropos hook
    # post` into `tool.execute.after` (Layer 3). Uses `sync` so a re-run is a
    # no-op when the content is identical.
    private def scaffold_opencode(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".opencode", "plugins", "agent-apropos.js").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, OPENCODE_PLUGIN_JS, existing, ".opencode/plugins/agent-apropos.js")
    end

    # Write (or merge into) `.gemini/settings.json`: Gemini CLI's `AfterTool`
    # event is the only one whose output schema supports injecting text back
    # into the model's context (`hookSpecificOutput.additionalContext`) — its
    # `BeforeTool` event can only override tool arguments or block the call.
    # So both `agent-apropos hook pre` (Layer 2) and `agent-apropos hook post` (Layer 3)
    # run there, matched on Gemini's file-editing tools (`write_file`,
    # `replace`); `Hook.pre`'s Layer 2 matching only needs the edited file's
    # path, which `AfterTool`'s payload still carries, so Layer 2 rules still
    # fire — just after the edit rather than before it. `agent-apropos hook pre`
    # also runs there matched on `read_file` alone, so Layer 2 can land on
    # the model's first read instead of only once it (mis)writes there. Also
    # points Gemini's configurable context filename at `AGENTS.md`, so Layer
    # 1 needs no symlink the way Claude's CLAUDE.md does.
    private def merge_gemini_settings(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".gemini", "settings.json").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, merged_gemini_settings(existing), existing, ".gemini/settings.json")
    end

    private def merged_gemini_settings(existing : String?) : String
      root = settings_root(existing, ".gemini/settings.json")
      hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
      groups = (hooks["AfterTool"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
      groups = ensure_gemini_group(groups)
      groups = ensure_gemini_read_group(groups)
      hooks["AfterTool"] = JSON::Any.new(groups)
      root["hooks"] = JSON::Any.new(hooks)
      root["context"] = merged_gemini_context(root["context"]?)
      JSON::Any.new(root).to_pretty_json + "\n"
    end

    # Converge to fully wired even when a prior run (or a hand-edit) left only
    # one of the two commands present: add the missing command(s) into the
    # existing agent-apropos-owned group rather than skipping just because *a*
    # agent-apropos command is already there, so a half-wired repo self-heals on
    # re-run instead of needing a manual JSON edit. Matching stays on the
    # generic "does this group carry an agent-apropos command" predicate (not the
    # matcher) so a user's own customization of the matcher (e.g. widening
    # it to cover another tool) still gets healed in place rather than
    # spawning a second, default-matcher group alongside it.
    #
    # `ensure_gemini_read_group`'s read-only group is explicitly excluded,
    # though: it is also agent-apropos-owned and also carries `agent-apropos hook pre`,
    # so the generic predicate alone can't tell the two groups apart — and if
    # it ran first (before this method's own group exists, e.g. from a
    # hand-edit with only that group present), it would be the first match
    # and get "healed" with `agent-apropos hook post` too, wiring Layer 3 onto
    # `read_file` and leaving the intended write/edit group never created.
    private def ensure_gemini_group(groups : Array(JSON::Any)) : Array(JSON::Any)
      index = groups.index { |group| agent_apropos_group?(group) && !gemini_read_group?(group) }
      return groups + [gemini_agent_apropos_group] if index.nil?

      groups = groups.dup
      groups[index] = with_missing_gemini_hooks(groups[index])
      groups
    end

    private def gemini_read_group?(group : JSON::Any) : Bool
      group.as_h?.try(&.["matcher"]?).try(&.as_s?) == "read_file"
    end

    # Also refreshes an already-present command's `timeout` to the current
    # `gemini_hook` shape, not just appends missing ones — so a repo that
    # ran `init` before the ms-vs-seconds timeout fix actually picks it up
    # on the next `init`, instead of staying stuck on the stale value
    # forever (only the delivery mechanism's own healing can fix this; the
    # settings file itself gives no other signal that the value is stale).
    private def with_missing_gemini_hooks(group : JSON::Any) : JSON::Any
      hash = group.as_h.dup
      present = hash["hooks"]?.try(&.as_a?) || [] of JSON::Any
      refreshed = present.map do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        command && GEMINI_HOOK_COMMANDS.includes?(command) ? gemini_hook(command) : hook
      end
      commands = present.compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
      missing = GEMINI_HOOK_COMMANDS.reject { |command| commands.includes?(command) }
      hash["hooks"] = JSON::Any.new(refreshed + missing.map { |command| gemini_hook(command) })
      JSON::Any.new(hash)
    end

    # A second, independent group matched on `read_file` alone, carrying only
    # `agent-apropos hook pre` — kept separate from `ensure_gemini_group`'s
    # write_file|replace group (rather than reusing its "does *any* agent-apropos
    # command already exist" check) because that check would see
    # `agent-apropos hook pre` already present in the *write* group and never add
    # this one. Matcher-keyed instead: find (or create) the group whose
    # matcher is exactly "read_file", and ensure it has the command — and,
    # same as `with_missing_gemini_hooks`, refresh it if already present
    # rather than no-op'ing, so a stale `timeout` here converges too instead
    # of getting stuck forever once the command already exists.
    private def ensure_gemini_read_group(groups : Array(JSON::Any)) : Array(JSON::Any)
      index = groups.index { |group| gemini_read_group?(group) }
      return groups + [gemini_read_group] if index.nil?

      groups = groups.dup
      groups[index] = with_missing_gemini_read_hook(groups[index])
      groups
    end

    private def with_missing_gemini_read_hook(group : JSON::Any) : JSON::Any
      hash = group.as_h.dup
      present = hash["hooks"]?.try(&.as_a?) || [] of JSON::Any
      refreshed = present.map do |hook|
        hook.as_h?.try(&.["command"]?).try(&.as_s?) == "agent-apropos hook pre" ? gemini_hook("agent-apropos hook pre") : hook
      end
      has_pre = refreshed.any? { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) == "agent-apropos hook pre" }
      hash["hooks"] = JSON::Any.new(has_pre ? refreshed : refreshed + [gemini_hook("agent-apropos hook pre")])
      JSON::Any.new(hash)
    end

    private def gemini_read_group : JSON::Any
      JSON::Any.new({
        "matcher" => JSON::Any.new("read_file"),
        "hooks"   => JSON::Any.new([gemini_hook("agent-apropos hook pre")]),
      })
    end

    # Add `AGENTS.md` to `context.fileName` (creating it as a one-element
    # array if absent), preserving every other filename a user already listed.
    private def merged_gemini_context(existing : JSON::Any?) : JSON::Any
      context = (existing.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
      names = context["fileName"]?
      list = names.try(&.as_a?) || names.try { |name| [name] } || [] of JSON::Any
      unless list.any? { |name| name.as_s? == GEMINI_CONTEXT_FILENAME }
        list = list + [JSON::Any.new(GEMINI_CONTEXT_FILENAME)]
      end
      context["fileName"] = JSON::Any.new(list)
      JSON::Any.new(context)
    end

    GEMINI_HOOK_COMMANDS = ["agent-apropos hook pre", "agent-apropos hook post"]

    # Gemini CLI's hook `timeout` is passed straight to JS `setTimeout()` —
    # milliseconds, not seconds like Claude Code's own hook `timeout`
    # (`AGENT_APROPOS_HOOK_PREFIX`'s callers above use a raw `10` for Claude,
    # correctly meaning 10 seconds there). Using the same literal `10` here
    # previously gave Gemini's AfterTool hooks a 10-*millisecond* budget,
    # well under the ~3-4ms `agent-apropos` itself needs just to spawn — any load
    # at all (e.g. another CLI agent running concurrently) tips it over, so
    # `agent-apropos hook pre`/`post` would intermittently get SIGTERM'd and
    # reported as failed. 10_000ms is the same 10-second intent, expressed
    # in Gemini's own unit.
    GEMINI_HOOK_TIMEOUT = 10_000_i64

    private def gemini_agent_apropos_group : JSON::Any
      JSON::Any.new({
        "matcher" => JSON::Any.new("write_file|replace"),
        "hooks"   => JSON::Any.new(GEMINI_HOOK_COMMANDS.map { |command| gemini_hook(command) }),
      })
    end

    private def gemini_hook(command : String) : JSON::Any
      JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new(command),
        "timeout" => JSON::Any.new(GEMINI_HOOK_TIMEOUT),
      })
    end

    # Write (or update) `.github/hooks/agent-apropos.json`. Unlike Claude/Gemini's
    # single shared settings file, Copilot CLI loads every `.github/hooks/*.json`
    # in the repo independently, so this file is entirely agent-apropos-owned — a
    # plain `sync`, no foreign-key-preserving merge needed.
    #
    # Copilot's `preToolUse` output schema is `permissionDecision`/`modifiedArgs`
    # only (no context field), so — as with Gemini's `AfterTool` — both Layer 2
    # and Layer 3 are wired onto `postToolUse` instead, matched the same way
    # Gemini's are: a `view`-only group carrying just `agent-apropos hook pre`,
    # and a `create|edit` group carrying both. The commands below call
    # `agent-apropos hook pre`/`post` directly — no bridge script — because
    # `Payload` (hooks/payload.cr) and `Hook.emit` (hook.cr) understand
    # Copilot's dialect natively: `toolArgs` as a JSON-encoded *string* keyed by
    # `path`/`file_text`/`old_str`/`new_str` (confirmed against a real captured
    # Copilot CLI hook payload, not upstream docs — its own reference types
    # `toolArgs` as `unknown`), and a flat `additionalContext` reply instead of
    # the `hookSpecificOutput` envelope every other wired agent expects.
    private def scaffold_copilot(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".github", "hooks", "agent-apropos.json").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, COPILOT_HOOKS_JSON, existing, ".github/hooks/agent-apropos.json")
    end

    # Copilot CLI's own hook `timeout` field (`timeoutSec`) is seconds, like
    # Claude Code's.
    COPILOT_HOOK_TIMEOUT = 10

    COPILOT_HOOKS_JSON = <<-JSON
      {
        "version": 1,
        "hooks": {
          "postToolUse": [
            {
              "type": "command",
              "matcher": "view",
              "command": "agent-apropos hook pre",
              "timeoutSec": #{COPILOT_HOOK_TIMEOUT}
            },
            {
              "type": "command",
              "matcher": "create|edit",
              "command": "agent-apropos hook pre",
              "timeoutSec": #{COPILOT_HOOK_TIMEOUT}
            },
            {
              "type": "command",
              "matcher": "create|edit",
              "command": "agent-apropos hook post",
              "timeoutSec": #{COPILOT_HOOK_TIMEOUT}
            }
          ]
        }
      }
      JSON

    # Alias CLAUDE.md → AGENTS.md so the same Layer 1 file serves both loaders.
    # Absent-only: an existing CLAUDE.md (real file or link) is left untouched.
    private def link_claude(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      link = repo_root.join("CLAUDE.md").to_s
      if fs.exists?(link)
        stdout.puts "exists   CLAUDE.md"
        return
      end
      if options.dry_run
        stdout.puts "would link CLAUDE.md -> AGENTS.md"
      else
        fs.symlink("AGENTS.md", link)
        stdout.puts "linked   CLAUDE.md -> AGENTS.md"
      end
    end

    CONVENTIONS_README = <<-MD
      # Conventions

      This directory is the single source of truth for scoped guidance — the
      judgment calls a linter or formatter cannot enforce. It implements the Agent
      Documentation Structure Standard. Universal, always-apply rules live in the
      root `AGENTS.md`; anything a tool can enforce lives in that tool.

      ## The four layers

      | Layer | For | Trigger | Delivered by |
      | --- | --- | --- | --- |
      | 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
      | 2 Path-scoped | Guidance for a path / file type | File **path** | PreToolUse hook |
      | 3 Construct-scoped | Guidance for an API / construct | Written **content** (regex), optionally AND path | PostToolUse hook |
      | 4 Intent skills | Task-nature guidance | Skill match | Generated `.claude/skills/*/SKILL.md` |

      ## Frontmatter

      ```yaml
      ---
      paths: ["src/**"]              # Layer 2: inject when editing a matching path
      contents: ['\\bTODO\\b']        # Layer 3: inject when written code matches (PCRE2)
      skill: true                    # Layer 4: generate a skill wrapper
      description: "Use when ..."    # required iff skill: true; must start with "Use when"
      ---
      ```

      - `paths` only → Layer 2 (fires on any edit to a matching path)
      - `contents` only → Layer 3 (fires when written code matches, anywhere)
      - `paths` + `contents` → **AND** (path-scoped Layer 3)
      - `skill: true` is independent and may combine with either
      - no frontmatter → reference-only: reachable by link, never triggered

      ## Writing a rule

      - One concern per file; keep it short — tight rules get read, long ones get skimmed.
      - State **what** the rule is, **why** it exists, and a verification criterion.
      - Add an optional `## Verify` heading; `agent-apropos review` harvests it as a checklist item.

      Claude Code delivers Layer 2 via PreToolUse `additionalContext`; run
      `agent-apropos doctor` to verify the version. OpenCode delivers Layer 2 via
      `tool.execute.before` and Layer 3 via `tool.execute.after`, injecting
      context with `noReply: true` through the generated plugin. Gemini CLI and
      GitHub Copilot CLI both have no pre-edit context-injection event (Gemini's
      `BeforeTool` and Copilot's `preToolUse` can only override arguments or
      block/allow the call), so both Layer 2 and Layer 3 deliver via their
      post-edit hook instead (`AfterTool` for Gemini, `postToolUse` for Copilot)
      — Layer 2 still fires, just after the edit rather than before it.
      MD

    AGENTS_SKELETON = <<-MD
      # Project

      <!-- Layer 1: universal, always-loaded rules. Keep this tight — a bloated
           root file gets skimmed. Scoped guidance belongs in docs/conventions/. -->

      ## Commands

      ## Universal rules

      ## Where scoped guidance lives

      Task- and file-scoped conventions are **not** in this file. They live in
      `docs/conventions/` and are surfaced automatically at edit time by agent-apropos's
      hooks. See `docs/conventions/README.md`.
      MD

    SKILLS_GITKEEP = <<-MD
      # Generated skill wrappers live here.
      #
      # `agent-apropos generate` writes `<slug>/SKILL.md` for every `skill: true` doc in
      # docs/conventions/. Do not edit these by hand — edit the source doc instead;
      # `agent-apropos generate --check` fails if a wrapper drifts from its source.
      MD

    EXAMPLE_L2 = <<-MD
      ---
      paths: ["src/**"]
      ---

      # Source files

      Keep modules small and single-purpose. This is an example Layer 2 rule: it is
      injected whenever a file under `src/` is edited. Replace it with a real
      convention or delete it.

      ## Verify

      - The change keeps one concern per file.
      MD

    EXAMPLE_L3 = <<-MD
      ---
      contents: ['\\bTODO\\b']
      ---

      # Leftover TODOs

      This is an example Layer 3 rule: it is injected when written content matches
      the `contents` regex (here, a stray `TODO`). Replace it with a real
      construct-scoped convention or delete it.
      MD

    EXAMPLE_SKILL = <<-MD
      ---
      skill: true
      description: "Use when shipping a change end to end"
      ---

      # Shipping a change

      This is an example Layer 4 skill doc. `agent-apropos generate` turns it into a
      `.claude/skills/example-skill/SKILL.md` wrapper. Replace it with a real
      workflow or delete it.
      MD

    # The OpenCode Bun plugin written by `agent-apropos init --tool opencode`
    # (or auto-detected when `opencode` is on PATH).
    #
    # Injects convention context using `client.session.prompt` with
    # `noReply: true`, which adds a message to the conversation without
    # triggering a new AI turn. This is the documented OpenCode API for
    # injecting context from plugins.
    #
    # Layer 2 (path-scoped) fires via `tool.execute.before` — on both a write
    # and a read (Layer 2 depends only on the target path, which a read
    # carries exactly like an edit, so the rule can land on the model's
    # first read instead of only once it writes there). Layer 3
    # (construct-scoped) fires via `tool.execute.after` using the written
    # content for regex matching — read-only, since it needs content that
    # doesn't exist yet on a mere read.
    #
    # Both hooks fail open: any error exits silently and never blocks an edit.
    # The session ID is read from `input.sessionID` when available and tracked
    # through session events as a fallback.
    OPENCODE_PLUGIN_JS = <<-JS
      // Generated by `agent-apropos init --tool opencode` — do not edit. Re-run to regenerate.
      //
      // Bridges agent-apropos's hook system into OpenCode using client.session.prompt
      // with noReply:true, which injects convention context into the conversation
      // without triggering an AI response.
      //
      // Layer 2 (path-scoped)    — fires via tool.execute.before (reads and pre-write).
      // Layer 3 (construct-scoped) — fires via tool.execute.after  (post-write).
      // Both fail open: any error produces no output and never blocks an edit.
      // See docs/conventions/README.md for the layer model.

      export const AgentAproposPlugin = async ({ worktree, client }) => {
        // Session ID tracked through events; also read from input.sessionID when
        // the plugin event exposes it (undocumented but likely present).
        let sessionID = null

        async function callHook(sub, payload) {
          try {
            const proc = Bun.spawn(["agent-apropos", "hook", sub], {
              stdin: new Blob([JSON.stringify(payload)]),
              stdout: "pipe",
              cwd: worktree,
            })
            const text = await new Response(proc.stdout).text()
            const parsed = JSON.parse(text.trim())
            return parsed?.hookSpecificOutput?.additionalContext ?? ""
          } catch {
            return ""
          }
        }

        async function inject(sid, ctx) {
          if (!ctx || !sid) return
          try {
            await client.session.prompt({
              path: { id: sid },
              body: { noReply: true, parts: [{ type: "text", text: ctx }] },
            })
          } catch {
            // Fail open
          }
        }

        function makePayload(input, args, withContent) {
          return {
            session_id: input.sessionID ?? sessionID,
            cwd: worktree,
            tool_name: input.tool,
            tool_input: {
              file_path: args?.filePath,
              ...(withContent ? {
                content:    args?.content,
                new_string: args?.newString,
              } : {}),
            },
          }
        }

        return {
          // Track session ID so inject() can call client.session.prompt.
          event: async ({ event }) => {
            const id = event.properties?.session?.id ?? event.properties?.id
            if (id && (event.type === "session.created" || event.type === "session.updated")) {
              sessionID = id
            }
          },

          // Layer 2 — path-scoped: inject BEFORE the write so the model sees
          // the rule while still in the current tool-processing turn. Also
          // fires on "read" — Layer 2 depends only on the target path, which
          // a read carries exactly like an edit, so the rule can land as
          // early as the model's first read instead of only once it writes
          // there. OpenCode delivers the tool arguments in the SECOND
          // callback parameter (output.args) for tool.execute.before; older
          // builds put them on input.args. Read output first, fall back to
          // input.
          "tool.execute.before": async (input, output) => {
            if (!["edit", "write", "apply_patch", "read"].includes(input.tool)) return
            const args = output?.args ?? input.args
            if (!args?.filePath) return
            const ctx = await callHook("pre", makePayload(input, args, false))
            await inject(input.sessionID ?? sessionID, ctx)
          },

          // Layer 3 — construct-scoped: inject AFTER the write using the written
          // content for regex matching. Here OpenCode carries args on input;
          // the same output-first fallback keeps this robust across versions.
          "tool.execute.after": async (input, output) => {
            if (!["edit", "write", "apply_patch"].includes(input.tool)) return
            const args = output?.args ?? input.args
            if (!args?.filePath) return
            const ctx = await callHook("post", makePayload(input, args, true))
            await inject(input.sessionID ?? sessionID, ctx)
          },
        }
      }
      JS
  end
end
