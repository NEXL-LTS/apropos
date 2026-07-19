require "json"
require "./errors"
require "./filesystem"
require "./environment"

module Apropos
  # `apropos init`: bootstrap the convention structure into a repo.
  # Idempotent — safe to re-run; a scaffold file is written only when absent
  # unless `--force` is given, and the `.claude/settings.json` and `.gitignore`
  # merges are additive (foreign keys and other hooks are preserved). `--dry-run`
  # prints what would change and writes nothing.
  #
  # Per-tool hook wiring (Claude Code's `.claude/settings.json`, OpenCode's
  # generated plugin, Gemini CLI's `.gemini/settings.json`) is tool-agnostic:
  # pass `--tool claude` / `--tool opencode` / `--tool gemini` (repeatable) to
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
  # init is an authoring command, so it fails **closed**: a malformed existing
  # `settings.json` is an error, not a silent overwrite.
  module Init
    extend self

    class Error < Apropos::Error
    end

    # CLI agents init knows how to wire hooks for. Extend this set as more
    # emitters land (Codex, GitHub Copilot CLI, Cursor CLI, ...).
    KNOWN_TOOLS = Set{"claude", "opencode", "gemini"}

    # The context filename apropos points Gemini CLI at, so Layer 1 reads the
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

    # apropos identifies its own settings entries by this command prefix, so a
    # merge never duplicates a group it already installed.
    APROPOS_HOOK_PREFIX = "apropos hook"

    CACHE_IGNORE_ENTRY = ".cache/apropos/"

    # Printed once per run to point at the bootstrapping prompt — most repos
    # arrive with docs already scattered across READMEs/wikis/comments, and an
    # agent can sort those into layers faster than a human writing from scratch.
    NEXT_STEPS_HINT = "next     have your agent bootstrap docs/conventions/ from your existing " \
                      "docs — see README.md#bootstrapping-from-an-existing-codebase"

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
      stdout.puts NEXT_STEPS_HINT unless options.dry_run
      0
    rescue ex : Apropos::Error
      stderr.puts "apropos init: #{ex.message}"
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
      create(repo_root, fs, options, stdout, "docs/conventions/README.md", CONVENTIONS_README)
      create(repo_root, fs, options, stdout, "docs/conventions/workflows/.gitkeep", "")
      create(repo_root, fs, options, stdout, ".claude/skills/.gitkeep", SKILLS_GITKEEP)
      # The root file is the user's own Layer 1 content — never overwrite it, even
      # under --force; only scaffold it when absent.
      create(repo_root, fs, options, stdout, "AGENTS.md", AGENTS_SKELETON, force_allowed: false)
    end

    private def write_examples(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      create(repo_root, fs, options, stdout, "docs/conventions/example-path-rule.md", EXAMPLE_L2)
      create(repo_root, fs, options, stdout, "docs/conventions/example-content-rule.md", EXAMPLE_L3)
      create(repo_root, fs, options, stdout, "docs/conventions/workflows/example-skill.md", EXAMPLE_SKILL)
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

    # Merge apropos's PreToolUse/PostToolUse hook groups into an existing (or new)
    # settings object, preserving every other key and hook and adding a group
    # only when apropos's own command is not already wired for that event.
    private def merged_settings(existing : String?) : String
      root = settings_root(existing, ".claude/settings.json")
      hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
      {"PreToolUse" => "pre", "PostToolUse" => "post"}.each do |event, sub|
        groups = (hooks[event]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        groups << apropos_group(sub) unless groups.any? { |group| apropos_group?(group) }
        hooks[event] = JSON::Any.new(groups)
      end
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

    private def apropos_group?(group : JSON::Any) : Bool
      hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
      return false unless hooks
      hooks.any? do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        !command.nil? && command.starts_with?(APROPOS_HOOK_PREFIX)
      end
    end

    private def apropos_group(sub : String) : JSON::Any
      hook = JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new("apropos hook #{sub}"),
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
        return "# apropos trigger index + session state (regenerated; not committed).\n" \
               "#{CACHE_IGNORE_ENTRY}\n"
      end
      return existing if existing.each_line.any? { |line| line.strip == CACHE_IGNORE_ENTRY }
      separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
      "#{existing}#{separator}#{CACHE_IGNORE_ENTRY}\n"
    end

    # Write (or update) the OpenCode Bun plugin that bridges `apropos hook pre`
    # into OpenCode's `tool.execute.before` event (Layer 2) and `apropos hook
    # post` into `tool.execute.after` (Layer 3). Uses `sync` so a re-run is a
    # no-op when the content is identical.
    private def scaffold_opencode(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".opencode", "plugins", "apropos.js").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, OPENCODE_PLUGIN_JS, existing, ".opencode/plugins/apropos.js")
    end

    # Write (or merge into) `.gemini/settings.json`: Gemini CLI's `AfterTool`
    # event is the only one whose output schema supports injecting text back
    # into the model's context (`hookSpecificOutput.additionalContext`) — its
    # `BeforeTool` event can only override tool arguments or block the call.
    # So both `apropos hook pre` (Layer 2) and `apropos hook post` (Layer 3)
    # run there, matched on Gemini's file-editing tools (`write_file`,
    # `replace`); `Hook.pre`'s Layer 2 matching only needs the edited file's
    # path, which `AfterTool`'s payload still carries, so Layer 2 rules still
    # fire — just after the edit rather than before it. Also points Gemini's
    # configurable context filename at `AGENTS.md`, so Layer 1 needs no
    # symlink the way Claude's CLAUDE.md does.
    private def merge_gemini_settings(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".gemini", "settings.json").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, merged_gemini_settings(existing), existing, ".gemini/settings.json")
    end

    private def merged_gemini_settings(existing : String?) : String
      root = settings_root(existing, ".gemini/settings.json")
      hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
      groups = (hooks["AfterTool"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
      groups << gemini_apropos_group unless groups.any? { |group| apropos_group?(group) }
      hooks["AfterTool"] = JSON::Any.new(groups)
      root["hooks"] = JSON::Any.new(hooks)
      root["context"] = merged_gemini_context(root["context"]?)
      JSON::Any.new(root).to_pretty_json + "\n"
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

    private def gemini_apropos_group : JSON::Any
      pre = JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new("apropos hook pre"),
        "timeout" => JSON::Any.new(10_i64),
      })
      post = JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new("apropos hook post"),
        "timeout" => JSON::Any.new(10_i64),
      })
      JSON::Any.new({
        "matcher" => JSON::Any.new("write_file|replace"),
        "hooks"   => JSON::Any.new([pre, post]),
      })
    end

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
      - Add an optional `## Verify` heading; `apropos review` harvests it as a checklist item.

      Claude Code delivers Layer 2 via PreToolUse `additionalContext`; run
      `apropos doctor` to verify the version. OpenCode delivers Layer 2 via
      `tool.execute.before` and Layer 3 via `tool.execute.after`, injecting
      context with `noReply: true` through the generated plugin. Gemini CLI has
      no pre-edit context-injection event, so both Layer 2 and Layer 3 deliver
      via its `AfterTool` hook instead — Layer 2 still fires, just after the
      edit rather than before it.
      MD

    AGENTS_SKELETON = <<-MD
      # Project

      <!-- Layer 1: universal, always-loaded rules. Keep this tight — a bloated
           root file gets skimmed. Scoped guidance belongs in docs/conventions/. -->

      ## Commands

      ## Universal rules

      ## Where scoped guidance lives

      Task- and file-scoped conventions are **not** in this file. They live in
      `docs/conventions/` and are surfaced automatically at edit time by apropos's
      hooks. See `docs/conventions/README.md`.
      MD

    SKILLS_GITKEEP = <<-MD
      # Generated skill wrappers live here.
      #
      # `apropos generate` writes `<slug>/SKILL.md` for every `skill: true` doc in
      # docs/conventions/. Do not edit these by hand — edit the source doc instead;
      # `apropos generate --check` fails if a wrapper drifts from its source.
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

      This is an example Layer 4 skill doc. `apropos generate` turns it into a
      `.claude/skills/example-skill/SKILL.md` wrapper. Replace it with a real
      workflow or delete it.
      MD

    # The OpenCode Bun plugin written by `apropos init --tool opencode`
    # (or auto-detected when `opencode` is on PATH).
    #
    # Injects convention context using `client.session.prompt` with
    # `noReply: true`, which adds a message to the conversation without
    # triggering a new AI turn. This is the documented OpenCode API for
    # injecting context from plugins.
    #
    # Layer 2 (path-scoped) fires via `tool.execute.before` — BEFORE the write —
    # so the model sees the matching rule while it is still processing the current
    # tool turn. Layer 3 (construct-scoped) fires via `tool.execute.after` using
    # the written content for regex matching.
    #
    # Both hooks fail open: any error exits silently and never blocks an edit.
    # The session ID is read from `input.sessionID` when available and tracked
    # through session events as a fallback.
    OPENCODE_PLUGIN_JS = <<-JS
      // Generated by `apropos init --tool opencode` — do not edit. Re-run to regenerate.
      //
      // Bridges apropos's hook system into OpenCode using client.session.prompt
      // with noReply:true, which injects convention context into the conversation
      // without triggering an AI response.
      //
      // Layer 2 (path-scoped)    — fires via tool.execute.before (pre-write).
      // Layer 3 (construct-scoped) — fires via tool.execute.after  (post-write).
      // Both fail open: any error produces no output and never blocks an edit.
      // See docs/conventions/README.md for the layer model.

      export const AproposPlugin = async ({ worktree, client }) => {
        // Session ID tracked through events; also read from input.sessionID when
        // the plugin event exposes it (undocumented but likely present).
        let sessionID = null

        async function callHook(sub, payload) {
          try {
            const proc = Bun.spawn(["apropos", "hook", sub], {
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
          // the rule while still in the current tool-processing turn.
          // OpenCode delivers the tool arguments in the SECOND callback
          // parameter (output.args) for tool.execute.before; older builds put
          // them on input.args. Read output first, fall back to input.
          "tool.execute.before": async (input, output) => {
            if (!["edit", "write", "apply_patch"].includes(input.tool)) return
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
