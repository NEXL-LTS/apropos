require "../spec_helper"

private ROOT                 = Path["/repo"]
private README_PATH          = "/repo/docs/conventions/README.md"
private AGENTS_PATH          = "/repo/AGENTS.md"
private SETTINGS_PATH        = "/repo/.claude/settings.json"
private GITIGNORE            = "/repo/.gitignore"
private PLUGIN_PATH          = "/repo/.opencode/plugins/agent-apropos.js"
private GEMINI_SETTINGS_PATH = "/repo/.gemini/settings.json"

# A configurable Environment double: `present` is the set of CLI agent
# binaries that resolve on PATH, used to exercise auto-detection.
private class FakeEnv < AgentApropos::Environment
  def initialize(@present : Set(String) = Set(String).new)
  end

  def which(command : String) : String?
    @present.includes?(command) ? "/usr/bin/#{command}" : nil
  end

  def run_capture(command : String, args : Array(String)) : String?
    nil
  end
end

# Defaults to both supported agents present on PATH, so examples that are not
# about tool selection itself keep exercising the full scaffold.
private def run_init(fs : AgentApropos::Filesystem,
                     options : AgentApropos::Init::Options = AgentApropos::Init::Options.new,
                     env : AgentApropos::Environment = FakeEnv.new(Set{"claude", "opencode"})) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Init.run(ROOT, fs, env, options, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

describe AgentApropos::Init do
  describe "scaffolding" do
    it "creates the full structure in a fresh repo" do
      fs = InMemoryFS.new
      code, stdout, stderr = run_init(fs)
      code.should eq(0)
      stderr.should be_empty

      fs.files[README_PATH].should contain("The four layers")
      fs.files.has_key?("/repo/docs/conventions/workflows/.gitkeep").should be_true
      fs.files["/repo/.claude/skills/.gitkeep"].should contain("Do not edit")
      fs.files[AGENTS_PATH].should contain("Where scoped guidance lives")
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook pre")
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook post")
      fs.files[GITIGNORE].should contain(".cache/agent-apropos/")
      stdout.should contain("created  docs/conventions/README.md")
    end

    it "points at the bootstrapping prompt with a full URL, not a relative path" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs)
      stdout.should contain("https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase")
    end

    it "is idempotent — a second run changes nothing" do
      fs = InMemoryFS.new
      run_init(fs)
      settings_before = fs.files[SETTINGS_PATH]

      _, stdout, _ = run_init(fs)
      stdout.should contain("exists   docs/conventions/README.md")
      stdout.should contain("current  .claude/settings.json")
      stdout.should contain("current  .gitignore")
      fs.files[SETTINGS_PATH].should eq(settings_before)
      # Once for the Edit|Write group, once for the Read group — not duplicated
      # within either.
      fs.files[SETTINGS_PATH].scan("agent-apropos hook pre").size.should eq(2)
    end

    it "overwrites managed scaffolds with --force but never the root file" do
      fs = InMemoryFS.new({README_PATH => "old readme", AGENTS_PATH => "custom root"})
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(force: true))
      stdout.should contain("updated  docs/conventions/README.md")
      stdout.should contain("exists   AGENTS.md")
      fs.files[README_PATH].should contain("The four layers")
      fs.files[AGENTS_PATH].should eq("custom root")
    end

    it "writes nothing under --dry-run" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(dry_run: true))
      stdout.should contain("would create docs/conventions/README.md")
      stdout.should contain("would create .claude/settings.json")
      stdout.should_not contain("https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase")
      fs.files.should be_empty
    end

    it "scaffolds into agent-apropos.yml's configured conventions_dir instead of the default" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      _, stdout, _ = run_init(fs)
      fs.files.has_key?("/repo/../shared-conventions/README.md").should be_true
      fs.files.has_key?("/repo/docs/conventions/README.md").should be_false
      stdout.should contain("created  ../shared-conventions/README.md")
    end
  end

  describe "--example" do
    it "drops one L2, one L3, and one skill doc" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(example: true))
      fs.files["/repo/docs/conventions/example-path-rule.md"].should contain("paths:")
      fs.files["/repo/docs/conventions/example-content-rule.md"].should contain("contents:")
      fs.files["/repo/docs/conventions/workflows/example-skill.md"].should contain("skill: true")
    end
  end

  describe "--claude-symlink" do
    it "aliases CLAUDE.md to AGENTS.md" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      fs.symlinks["/repo/CLAUDE.md"].should eq("AGENTS.md")
      stdout.should contain("linked   CLAUDE.md -> AGENTS.md")
    end

    it "leaves an existing CLAUDE.md untouched" do
      fs = InMemoryFS.new({"/repo/CLAUDE.md" => "real file"})
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      fs.symlinks.has_key?("/repo/CLAUDE.md").should be_false
      stdout.should contain("exists   CLAUDE.md")
    end

    it "reports the link under --dry-run without creating it" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true, dry_run: true))
      fs.symlinks.should be_empty
      stdout.should contain("would link CLAUDE.md -> AGENTS.md")
    end
  end

  describe "settings.json merge" do
    it "preserves foreign keys and other hooks while adding agent-apropos's" do
      seed = <<-JSON
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo hi" } ] }
            ]
          }
        }
        JSON
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain(%("model": "opus"))
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook pre")
      merged.should contain("agent-apropos hook post")
    end

    it "does not duplicate a agent-apropos group it already installed" do
      fs = InMemoryFS.new
      run_init(fs) # installs agent-apropos hooks
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .claude/settings.json")
      fs.files[SETTINGS_PATH].scan("agent-apropos hook post").size.should eq(1)
    end

    it "does not add an already-installed command into a second group sharing the same matcher" do
      # Legacy layout: an older agent-apropos version (or a hand-edit) put its
      # own command in a *separate* "Edit|Write" group instead of the foreign
      # hook's group. `ensure_commands` must search every group with this
      # matcher for the command, not just the first one it finds — otherwise
      # it heals the foreign hook's group by adding a second copy alongside
      # the one already installed in the other group.
      seed = %({"hooks":{"PostToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"bash myscript.sh","timeout":30}]},) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook post","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("bash myscript.sh")
      merged.scan("agent-apropos hook post").size.should eq(1)
    end

    it "replaces a non-array event value and a group with no hooks list" do
      seed = %({"hooks": {"PreToolUse": "weird", "PostToolUse": [{"matcher": "X"}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("agent-apropos hook pre")
      merged.should contain("agent-apropos hook post")
      merged.should contain(%("matcher": "X")) # foreign group preserved
    end

    it "ignores a non-agent-apropos command hook when deciding to add its group" do
      seed = %({"hooks": {"PostToolUse": [{"hooks": [{"type": "command"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook post")
    end

    it "fails closed on malformed existing settings JSON" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      code, _, stderr = run_init(fs)
      code.should eq(1)
      stderr.should contain("not valid JSON")
    end

    it "fails closed when existing settings is not a JSON object" do
      fs = InMemoryFS.new({SETTINGS_PATH => "[]"})
      code, _, stderr = run_init(fs)
      code.should eq(1)
      stderr.should contain("must be a JSON object")
    end

    it "wires agent-apropos hook pre onto Read too, distinct from the Edit|Write group" do
      fs = InMemoryFS.new
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.should contain(%("matcher": "Read"))
      merged.should contain(%("matcher": "Edit|Write"))
    end

    it "adds agent-apropos hook pre into an existing Read group that has a different command" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"echo hi"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook pre")
      merged.scan(%("matcher": "Read")).size.should eq(1)
    end

    it "does not mistake an existing Read group for the Edit|Write group to heal" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      # Isolate PreToolUse: PostToolUse gets its own independent "Edit|Write"
      # group (for agent-apropos hook post), which would mask a missing PreToolUse
      # one if counted across the whole file.
      pre_section = fs.files[SETTINGS_PATH].split(%("PostToolUse"))[0]
      pre_section.scan(%("matcher": "Read")).size.should eq(1)
      pre_section.scan(%("matcher": "Edit|Write")).size.should eq(1)
    end

    it "refreshes a stale timeout on the Read group's own pre command too" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":999}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      pre_section = fs.files[SETTINGS_PATH].split(%("PostToolUse"))[0]
      pre_section.should_not contain(%("timeout": 999))
      pre_section.scan(%("timeout": 10)).size.should eq(2) # Read's own pre, Edit|Write's pre
    end

    it "budgets Claude Code's hook timeout in seconds" do
      fs = InMemoryFS.new
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain(%("timeout": 10))
      merged.should_not contain(%("timeout": 10000))
    end

    it "does not duplicate the Read group on a second run" do
      fs = InMemoryFS.new
      run_init(fs)
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan(%("matcher": "Read")).size.should eq(1)
    end
  end

  describe "--tool (explicit selection)" do
    it "wires only the explicitly named tool, ignoring what else is on PATH" do
      fs = InMemoryFS.new
      code, stdout, stderr = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"opencode"}))
      code.should eq(0)
      stderr.should be_empty
      fs.files.has_key?(SETTINGS_PATH).should be_false
      plugin = fs.files[PLUGIN_PATH]
      plugin.should contain("tool.execute.before")
      plugin.should contain("tool.execute.after")
      plugin.should contain("noReply: true")
      plugin.should contain(%(["agent-apropos", "hook", sub]))
      # OpenCode delivers tool args in the second callback parameter; the plugin
      # must read from there (falling back to input) or Layer 2 never fires.
      plugin.should contain("async (input, output)")
      plugin.should contain("output?.args ?? input.args")
      # Layer 2 fires on OpenCode's "read" tool too, via the same "pre" hook.
      plugin.should contain(%("edit", "write", "apply_patch", "read"))
      stdout.should contain(".opencode/plugins/agent-apropos.js")
    end

    it "wires every named tool when --tool is repeated, regardless of PATH" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"claude", "opencode"}), FakeEnv.new)
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_true
    end

    it "does not narrate detection — an explicit selection is the user's own words" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"claude"}))
      stdout.should_not contain("detected")
    end

    it "is idempotent — re-running reports current" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"opencode"}))
      plugin_before = fs.files[PLUGIN_PATH]
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"opencode"}))
      stdout.should contain("current  .opencode/plugins/agent-apropos.js")
      fs.files[PLUGIN_PATH].should eq(plugin_before)
    end

    it "reports would-create under --dry-run without writing" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"opencode"}, dry_run: true))
      stdout.should contain("would create .opencode/plugins/agent-apropos.js")
      fs.files.has_key?(PLUGIN_PATH).should be_false
    end
  end

  describe "auto-detection (no --tool given)" do
    it "wires only Claude when only claude is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"claude"}))
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_false
      stdout.should contain("detected claude")
    end

    it "wires only OpenCode when only opencode is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"opencode"}))
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain("detected opencode")
    end

    it "wires both when both are on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"claude", "opencode"}))
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain("detected claude, opencode")
    end

    it "wires neither and says so when no supported agent is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new)
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_false
      stdout.should contain("no supported CLI agent found on PATH")
    end
  end

  describe "gemini settings.json merge" do
    it "writes AfterTool hooks and context.fileName" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      content = fs.files[GEMINI_SETTINGS_PATH]
      content.should contain("AfterTool")
      content.should contain("agent-apropos hook pre")
      content.should contain("agent-apropos hook post")
      content.should contain("write_file|replace")
      content.should contain(%("fileName"))
      content.should contain("AGENTS.md")
    end

    it "does not wire BeforeTool — Gemini's BeforeTool cannot inject context" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      fs.files[GEMINI_SETTINGS_PATH].should_not contain("BeforeTool")
    end

    it "is idempotent — re-running reports current and does not duplicate the group" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      before = fs.files[GEMINI_SETTINGS_PATH]

      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      stdout.should contain("current  .gemini/settings.json")
      fs.files[GEMINI_SETTINGS_PATH].should eq(before)
      # Once in the write_file|replace group, once in the read_file group.
      fs.files[GEMINI_SETTINGS_PATH].scan("agent-apropos hook pre").size.should eq(2)
    end

    it "adds the missing command into the existing group when only pre is present" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      # Once in the healed write_file|replace group, once in the freshly-added
      # read_file group.
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan("agent-apropos hook post").size.should eq(1)
      merged.scan(%("matcher": "write_file|replace")).size.should eq(1) # converged, not a second
    end

    it "adds the missing command into the existing group when only post is present" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook post","timeout":10}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan("agent-apropos hook post").size.should eq(1)
    end

    it "wires agent-apropos hook pre onto a read_file-matched AfterTool group too, distinct from write_file|replace" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      content = fs.files[GEMINI_SETTINGS_PATH]
      content.scan("agent-apropos hook pre").size.should eq(2)
      content.should contain(%("matcher": "read_file"))
    end

    it "budgets the AfterTool hook timeout in milliseconds, not Claude Code's seconds" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      fs.files[GEMINI_SETTINGS_PATH].should contain(%("timeout": 10000))
    end

    it "refreshes a stale timeout on an already-wired command when healing (e.g. after an agent-apropos upgrade)" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10},) +
             %({"type":"command","command":"agent-apropos hook post","timeout":10}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      # pre and post converged (not just newly-added commands), plus the
      # freshly-added read_file group's own pre command — all three at 10000.
      merged.scan(%("timeout": 10000)).size.should eq(3)
    end

    it "does not duplicate the read_file group on a second run" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan(%("matcher": "read_file")).size.should eq(1)
    end

    it "adds agent-apropos hook pre into an existing read_file group that has a different command" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"read_file","hooks":) +
             %([{"type":"command","command":"echo hi"}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook pre")
      merged.scan(%("matcher": "read_file")).size.should eq(1)
    end

    it "does not mistake an existing read_file group for the write group to heal" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"read_file","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10000}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.scan(%("matcher": "read_file")).size.should eq(1)
      merged.scan(%("matcher": "write_file|replace")).size.should eq(1)
      read_group = merged.split(%("matcher": "write_file|replace")).first
      read_group.should_not contain("agent-apropos hook post")
    end

    it "refreshes a stale timeout on the read_file group's own pre command too" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"read_file","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.should_not contain(%("timeout": 10,))
      merged.scan(%("timeout": 10000)).size.should eq(3) # read's pre, write's pre, write's post
    end

    it "preserves the group's matcher and a foreign hook alongside it while healing" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"custom_matcher","hooks":) +
             %([{"type":"command","command":"echo hi"},) +
             %({"type":"command","command":"agent-apropos hook pre"}]}]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.should contain(%("matcher": "custom_matcher"))
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook post")
    end

    it "preserves foreign keys and an existing fileName list" do
      seed = %({"model": "gemini-pro", "context": {"fileName": ["CONTEXT.md"]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.should contain(%("model": "gemini-pro"))
      merged.should contain("CONTEXT.md")
      merged.should contain("AGENTS.md")
    end

    it "does not duplicate AGENTS.md when it is already listed" do
      seed = %({"context": {"fileName": ["AGENTS.md"]}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      fs.files[GEMINI_SETTINGS_PATH].scan("AGENTS.md").size.should eq(1)
    end

    it "upgrades a single fileName string to an array rather than clobbering it" do
      seed = %({"context": {"fileName": "CONTEXT.md"}})
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => seed})
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      merged = fs.files[GEMINI_SETTINGS_PATH]
      merged.should contain("CONTEXT.md")
      merged.should contain("AGENTS.md")
    end

    it "fails closed on malformed existing gemini settings JSON" do
      fs = InMemoryFS.new({GEMINI_SETTINGS_PATH => "{not json"})
      code, _, stderr = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"gemini"}))
      code.should eq(1)
      stderr.should contain("not valid JSON")
    end

    it "auto-detects gemini on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"gemini"}))
      fs.files.has_key?(GEMINI_SETTINGS_PATH).should be_true
      stdout.should contain("detected gemini")
    end
  end

  describe ".gitignore merge" do
    it "appends the cache entry when missing, adding a separating newline" do
      fs = InMemoryFS.new({GITIGNORE => "/bin\n/lib"})
      run_init(fs)
      fs.files[GITIGNORE].should eq("/bin\n/lib\n.cache/agent-apropos/\n")
    end

    it "leaves the file unchanged when the entry is already present" do
      existing = "/bin\n.cache/agent-apropos/\n"
      fs = InMemoryFS.new({GITIGNORE => existing})
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .gitignore")
      fs.files[GITIGNORE].should eq(existing)
    end
  end
end
