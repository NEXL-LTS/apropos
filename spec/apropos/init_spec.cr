require "../spec_helper"

private ROOT          = Path["/repo"]
private README_PATH   = "/repo/docs/conventions/README.md"
private AGENTS_PATH   = "/repo/AGENTS.md"
private SETTINGS_PATH = "/repo/.claude/settings.json"
private GITIGNORE     = "/repo/.gitignore"
private PLUGIN_PATH   = "/repo/.opencode/plugins/apropos.js"

# A configurable Environment double: `present` is the set of CLI agent
# binaries that resolve on PATH, used to exercise auto-detection.
private class FakeEnv < Apropos::Environment
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
private def run_init(fs : Apropos::Filesystem,
                     options : Apropos::Init::Options = Apropos::Init::Options.new,
                     env : Apropos::Environment = FakeEnv.new(Set{"claude", "opencode"})) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Apropos::Init.run(ROOT, fs, env, options, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

describe Apropos::Init do
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
      fs.files[SETTINGS_PATH].should contain("apropos hook pre")
      fs.files[SETTINGS_PATH].should contain("apropos hook post")
      fs.files[GITIGNORE].should contain(".cache/apropos/")
      stdout.should contain("created  docs/conventions/README.md")
    end

    it "points at the bootstrapping prompt in README.md" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs)
      stdout.should contain("README.md#bootstrapping-from-an-existing-codebase")
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
      fs.files[SETTINGS_PATH].scan("apropos hook pre").size.should eq(1)
    end

    it "overwrites managed scaffolds with --force but never the root file" do
      fs = InMemoryFS.new({README_PATH => "old readme", AGENTS_PATH => "custom root"})
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(force: true))
      stdout.should contain("updated  docs/conventions/README.md")
      stdout.should contain("exists   AGENTS.md")
      fs.files[README_PATH].should contain("The four layers")
      fs.files[AGENTS_PATH].should eq("custom root")
    end

    it "writes nothing under --dry-run" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(dry_run: true))
      stdout.should contain("would create docs/conventions/README.md")
      stdout.should contain("would create .claude/settings.json")
      stdout.should_not contain("README.md#bootstrapping-from-an-existing-codebase")
      fs.files.should be_empty
    end
  end

  describe "--example" do
    it "drops one L2, one L3, and one skill doc" do
      fs = InMemoryFS.new
      run_init(fs, Apropos::Init::Options.new(example: true))
      fs.files["/repo/docs/conventions/example-path-rule.md"].should contain("paths:")
      fs.files["/repo/docs/conventions/example-content-rule.md"].should contain("contents:")
      fs.files["/repo/docs/conventions/workflows/example-skill.md"].should contain("skill: true")
    end
  end

  describe "--claude-symlink" do
    it "aliases CLAUDE.md to AGENTS.md" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(claude_symlink: true))
      fs.symlinks["/repo/CLAUDE.md"].should eq("AGENTS.md")
      stdout.should contain("linked   CLAUDE.md -> AGENTS.md")
    end

    it "leaves an existing CLAUDE.md untouched" do
      fs = InMemoryFS.new({"/repo/CLAUDE.md" => "real file"})
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(claude_symlink: true))
      fs.symlinks.has_key?("/repo/CLAUDE.md").should be_false
      stdout.should contain("exists   CLAUDE.md")
    end

    it "reports the link under --dry-run without creating it" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(claude_symlink: true, dry_run: true))
      fs.symlinks.should be_empty
      stdout.should contain("would link CLAUDE.md -> AGENTS.md")
    end
  end

  describe "settings.json merge" do
    it "preserves foreign keys and other hooks while adding apropos's" do
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
      merged.should contain("apropos hook pre")
      merged.should contain("apropos hook post")
    end

    it "does not duplicate a apropos group it already installed" do
      fs = InMemoryFS.new
      run_init(fs) # installs apropos hooks
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .claude/settings.json")
      fs.files[SETTINGS_PATH].scan("apropos hook post").size.should eq(1)
    end

    it "replaces a non-array event value and a group with no hooks list" do
      seed = %({"hooks": {"PreToolUse": "weird", "PostToolUse": [{"matcher": "X"}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("apropos hook pre")
      merged.should contain("apropos hook post")
      merged.should contain(%("matcher": "X")) # foreign group preserved
    end

    it "ignores a non-apropos command hook when deciding to add its group" do
      seed = %({"hooks": {"PostToolUse": [{"hooks": [{"type": "command"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      fs.files[SETTINGS_PATH].should contain("apropos hook post")
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
  end

  describe "--tool (explicit selection)" do
    it "wires only the explicitly named tool, ignoring what else is on PATH" do
      fs = InMemoryFS.new
      code, stdout, stderr = run_init(fs, Apropos::Init::Options.new(tools: Set{"opencode"}))
      code.should eq(0)
      stderr.should be_empty
      fs.files.has_key?(SETTINGS_PATH).should be_false
      plugin = fs.files[PLUGIN_PATH]
      plugin.should contain("tool.execute.before")
      plugin.should contain("tool.execute.after")
      plugin.should contain("noReply: true")
      plugin.should contain(%(["apropos", "hook", sub]))
      # OpenCode delivers tool args in the second callback parameter; the plugin
      # must read from there (falling back to input) or Layer 2 never fires.
      plugin.should contain("async (input, output)")
      plugin.should contain("output?.args ?? input.args")
      stdout.should contain(".opencode/plugins/apropos.js")
    end

    it "wires every named tool when --tool is repeated, regardless of PATH" do
      fs = InMemoryFS.new
      run_init(fs, Apropos::Init::Options.new(tools: Set{"claude", "opencode"}), FakeEnv.new)
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_true
    end

    it "does not narrate detection — an explicit selection is the user's own words" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(tools: Set{"claude"}))
      stdout.should_not contain("detected")
    end

    it "is idempotent — re-running reports current" do
      fs = InMemoryFS.new
      run_init(fs, Apropos::Init::Options.new(tools: Set{"opencode"}))
      plugin_before = fs.files[PLUGIN_PATH]
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(tools: Set{"opencode"}))
      stdout.should contain("current  .opencode/plugins/apropos.js")
      fs.files[PLUGIN_PATH].should eq(plugin_before)
    end

    it "reports would-create under --dry-run without writing" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new(tools: Set{"opencode"}, dry_run: true))
      stdout.should contain("would create .opencode/plugins/apropos.js")
      fs.files.has_key?(PLUGIN_PATH).should be_false
    end
  end

  describe "auto-detection (no --tool given)" do
    it "wires only Claude when only claude is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new, FakeEnv.new(Set{"claude"}))
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_false
      stdout.should contain("detected claude")
    end

    it "wires only OpenCode when only opencode is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new, FakeEnv.new(Set{"opencode"}))
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain("detected opencode")
    end

    it "wires both when both are on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new, FakeEnv.new(Set{"claude", "opencode"}))
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain("detected claude, opencode")
    end

    it "wires neither and says so when no supported agent is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Apropos::Init::Options.new, FakeEnv.new)
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_false
      stdout.should contain("no supported CLI agent found on PATH")
    end
  end

  describe ".gitignore merge" do
    it "appends the cache entry when missing, adding a separating newline" do
      fs = InMemoryFS.new({GITIGNORE => "/bin\n/lib"})
      run_init(fs)
      fs.files[GITIGNORE].should eq("/bin\n/lib\n.cache/apropos/\n")
    end

    it "leaves the file unchanged when the entry is already present" do
      existing = "/bin\n.cache/apropos/\n"
      fs = InMemoryFS.new({GITIGNORE => existing})
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .gitignore")
      fs.files[GITIGNORE].should eq(existing)
    end
  end
end
