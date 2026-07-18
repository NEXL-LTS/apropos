require "json"
require "./errors"
require "./filesystem"

module Muninn
  # `muninn init`: bootstrap the convention structure into a repo.
  # Idempotent — safe to re-run; a scaffold file is written only when absent
  # unless `--force` is given, and the `.claude/settings.json` and `.gitignore`
  # merges are additive (foreign keys and other hooks are preserved). `--dry-run`
  # prints what would change and writes nothing.
  #
  # init is an authoring command, so it fails **closed**: a malformed existing
  # `settings.json` is an error, not a silent overwrite.
  module Init
    extend self

    class Error < Muninn::Error
    end

    # Parsed flags for one `init` invocation.
    record Options,
      force : Bool = false,
      example : Bool = false,
      claude_symlink : Bool = false,
      dry_run : Bool = false,
      opencode : Bool = false

    # muninn identifies its own settings entries by this command prefix, so a
    # merge never duplicates a group it already installed.
    MUNINN_HOOK_PREFIX = "muninn hook"

    CACHE_IGNORE_ENTRY = ".cache/muninn/"

    def run(repo_root : Path, fs : Filesystem, options : Options, stdout : IO, stderr : IO) : Int32
      scaffold(repo_root, fs, options, stdout)
      merge_settings(repo_root, fs, options, stdout)
      merge_gitignore(repo_root, fs, options, stdout)
      write_examples(repo_root, fs, options, stdout) if options.example
      link_claude(repo_root, fs, options, stdout) if options.claude_symlink
      scaffold_opencode(repo_root, fs, options, stdout) if options.opencode
      0
    rescue ex : Muninn::Error
      stderr.puts "muninn init: #{ex.message}"
      1
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

    # Merge muninn's PreToolUse/PostToolUse hook groups into an existing (or new)
    # settings object, preserving every other key and hook and adding a group
    # only when muninn's own command is not already wired for that event.
    private def merged_settings(existing : String?) : String
      root = settings_root(existing)
      hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
      {"PreToolUse" => "pre", "PostToolUse" => "post"}.each do |event, sub|
        groups = (hooks[event]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        groups << muninn_group(sub) unless groups.any? { |group| muninn_group?(group) }
        hooks[event] = JSON::Any.new(groups)
      end
      root["hooks"] = JSON::Any.new(hooks)
      JSON::Any.new(root).to_pretty_json + "\n"
    end

    private def settings_root(existing : String?) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if existing.nil?
      parsed =
        begin
          JSON.parse(existing)
        rescue ex : JSON::ParseException
          raise Error.new("existing .claude/settings.json is not valid JSON: #{ex.message}")
        end
      hash = parsed.as_h?
      raise Error.new(".claude/settings.json must be a JSON object") if hash.nil?
      hash.dup
    end

    private def muninn_group?(group : JSON::Any) : Bool
      hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
      return false unless hooks
      hooks.any? do |hook|
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        !command.nil? && command.starts_with?(MUNINN_HOOK_PREFIX)
      end
    end

    private def muninn_group(sub : String) : JSON::Any
      hook = JSON::Any.new({
        "type"    => JSON::Any.new("command"),
        "command" => JSON::Any.new("muninn hook #{sub}"),
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
        return "# muninn trigger index + session state (regenerated; not committed).\n" \
               "#{CACHE_IGNORE_ENTRY}\n"
      end
      return existing if existing.each_line.any? { |line| line.strip == CACHE_IGNORE_ENTRY }
      separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
      "#{existing}#{separator}#{CACHE_IGNORE_ENTRY}\n"
    end

    # Write (or update) the OpenCode Bun plugin that bridges `muninn hook pre`
    # and `muninn hook post` into OpenCode's `tool.execute.after` event. Uses
    # `sync` so a re-run is a no-op when the content is identical.
    private def scaffold_opencode(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".opencode", "plugins", "muninn.js").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, OPENCODE_PLUGIN_JS, existing, ".opencode/plugins/muninn.js")
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
      - Add an optional `## Verify` heading; `muninn review` harvests it as a checklist item.

      Claude Code delivers Layer 2 via PreToolUse `additionalContext`; run
      `muninn doctor` to verify the version. OpenCode delivers Layer 2 via
      `tool.execute.before` and Layer 3 via `tool.execute.after`, injecting
      context with `noReply: true` through the generated plugin.
      MD

    AGENTS_SKELETON = <<-MD
      # Project

      <!-- Layer 1: universal, always-loaded rules. Keep this tight — a bloated
           root file gets skimmed. Scoped guidance belongs in docs/conventions/. -->

      ## Commands

      ## Universal rules

      ## Where scoped guidance lives

      Task- and file-scoped conventions are **not** in this file. They live in
      `docs/conventions/` and are surfaced automatically at edit time by muninn's
      hooks. See `docs/conventions/README.md`.
      MD

    SKILLS_GITKEEP = <<-MD
      # Generated skill wrappers live here.
      #
      # `muninn generate` writes `<slug>/SKILL.md` for every `skill: true` doc in
      # docs/conventions/. Do not edit these by hand — edit the source doc instead;
      # `muninn generate --check` fails if a wrapper drifts from its source.
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

      This is an example Layer 4 skill doc. `muninn generate` turns it into a
      `.claude/skills/example-skill/SKILL.md` wrapper. Replace it with a real
      workflow or delete it.
      MD

    # The OpenCode Bun plugin written by `muninn init --opencode`.
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
      // Generated by `muninn init --opencode` — do not edit. Re-run to regenerate.
      //
      // Bridges muninn's hook system into OpenCode using client.session.prompt
      // with noReply:true, which injects convention context into the conversation
      // without triggering an AI response.
      //
      // Layer 2 (path-scoped)    — fires via tool.execute.before (pre-write).
      // Layer 3 (construct-scoped) — fires via tool.execute.after  (post-write).
      // Both fail open: any error produces no output and never blocks an edit.
      // See docs/conventions/README.md for the layer model.

      export const MuninnPlugin = async ({ worktree, client }) => {
        // Session ID tracked through events; also read from input.sessionID when
        // the plugin event exposes it (undocumented but likely present).
        let sessionID = null

        async function callHook(sub, payload) {
          try {
            const proc = Bun.spawn(["muninn", "hook", sub], {
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

        function makePayload(input, withContent) {
          return {
            session_id: input.sessionID ?? sessionID,
            cwd: worktree,
            tool_name: input.tool,
            tool_input: {
              file_path: input.args?.filePath,
              ...(withContent ? {
                content:    input.args?.content,
                new_string: input.args?.newString,
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
          "tool.execute.before": async (input) => {
            if (!["edit", "write", "apply_patch"].includes(input.tool)) return
            if (!input.args?.filePath) return
            const ctx = await callHook("pre", makePayload(input, false))
            await inject(input.sessionID ?? sessionID, ctx)
          },

          // Layer 3 — construct-scoped: inject AFTER the write using the written
          // content for regex matching.
          "tool.execute.after": async (input) => {
            if (!["edit", "write", "apply_patch"].includes(input.tool)) return
            if (!input.args?.filePath) return
            const ctx = await callHook("post", makePayload(input, true))
            await inject(input.sessionID ?? sessionID, ctx)
          },
        }
      }
      JS
  end
end
