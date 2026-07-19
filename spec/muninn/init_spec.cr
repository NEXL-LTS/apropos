require "../spec_helper"

private ROOT          = Path["/repo"]
private README_PATH   = "/repo/docs/conventions/README.md"
private AGENTS_PATH   = "/repo/AGENTS.md"
private SETTINGS_PATH = "/repo/.claude/settings.json"
private GITIGNORE     = "/repo/.gitignore"

private def run_init(fs : Muninn::Filesystem,
                     options : Muninn::Init::Options = Muninn::Init::Options.new) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Muninn::Init.run(ROOT, fs, options, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

describe Muninn::Init do
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
      fs.files[SETTINGS_PATH].should contain("muninn hook pre")
      fs.files[SETTINGS_PATH].should contain("muninn hook post")
      fs.files[GITIGNORE].should contain(".cache/muninn/")
      stdout.should contain("created  docs/conventions/README.md")
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
      fs.files[SETTINGS_PATH].scan("muninn hook pre").size.should eq(1)
    end

    it "overwrites managed scaffolds with --force but never the root file" do
      fs = InMemoryFS.new({README_PATH => "old readme", AGENTS_PATH => "custom root"})
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(force: true))
      stdout.should contain("updated  docs/conventions/README.md")
      stdout.should contain("exists   AGENTS.md")
      fs.files[README_PATH].should contain("The four layers")
      fs.files[AGENTS_PATH].should eq("custom root")
    end

    it "writes nothing under --dry-run" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(dry_run: true))
      stdout.should contain("would create docs/conventions/README.md")
      stdout.should contain("would create .claude/settings.json")
      fs.files.should be_empty
    end
  end

  describe "--example" do
    it "drops one L2, one L3, and one skill doc" do
      fs = InMemoryFS.new
      run_init(fs, Muninn::Init::Options.new(example: true))
      fs.files["/repo/docs/conventions/example-path-rule.md"].should contain("paths:")
      fs.files["/repo/docs/conventions/example-content-rule.md"].should contain("contents:")
      fs.files["/repo/docs/conventions/workflows/example-skill.md"].should contain("skill: true")
    end
  end

  describe "--claude-symlink" do
    it "aliases CLAUDE.md to AGENTS.md" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(claude_symlink: true))
      fs.symlinks["/repo/CLAUDE.md"].should eq("AGENTS.md")
      stdout.should contain("linked   CLAUDE.md -> AGENTS.md")
    end

    it "leaves an existing CLAUDE.md untouched" do
      fs = InMemoryFS.new({"/repo/CLAUDE.md" => "real file"})
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(claude_symlink: true))
      fs.symlinks.has_key?("/repo/CLAUDE.md").should be_false
      stdout.should contain("exists   CLAUDE.md")
    end

    it "reports the link under --dry-run without creating it" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(claude_symlink: true, dry_run: true))
      fs.symlinks.should be_empty
      stdout.should contain("would link CLAUDE.md -> AGENTS.md")
    end
  end

  describe "settings.json merge" do
    it "preserves foreign keys and other hooks while adding muninn's" do
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
      merged.should contain("muninn hook pre")
      merged.should contain("muninn hook post")
    end

    it "does not duplicate a muninn group it already installed" do
      fs = InMemoryFS.new
      run_init(fs) # installs muninn hooks
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .claude/settings.json")
      fs.files[SETTINGS_PATH].scan("muninn hook post").size.should eq(1)
    end

    it "replaces a non-array event value and a group with no hooks list" do
      seed = %({"hooks": {"PreToolUse": "weird", "PostToolUse": [{"matcher": "X"}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("muninn hook pre")
      merged.should contain("muninn hook post")
      merged.should contain(%("matcher": "X")) # foreign group preserved
    end

    it "ignores a non-muninn command hook when deciding to add its group" do
      seed = %({"hooks": {"PostToolUse": [{"hooks": [{"type": "command"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_init(fs)
      fs.files[SETTINGS_PATH].should contain("muninn hook post")
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

  describe "--opencode" do
    it "creates the OpenCode plugin when --opencode is given" do
      fs = InMemoryFS.new
      code, stdout, stderr = run_init(fs, Muninn::Init::Options.new(opencode: true))
      code.should eq(0)
      stderr.should be_empty
      plugin = fs.files["/repo/.opencode/plugins/muninn.js"]
      plugin.should contain("tool.execute.before")
      plugin.should contain("tool.execute.after")
      plugin.should contain("noReply: true")
      plugin.should contain(%(["muninn", "hook", sub]))
      # OpenCode delivers tool args in the second callback parameter; the plugin
      # must read from there (falling back to input) or Layer 2 never fires.
      plugin.should contain("async (input, output)")
      plugin.should contain("output?.args ?? input.args")
      stdout.should contain(".opencode/plugins/muninn.js")
    end

    it "does not create the OpenCode plugin without --opencode" do
      fs = InMemoryFS.new
      run_init(fs)
      fs.files.has_key?("/repo/.opencode/plugins/muninn.js").should be_false
    end

    it "is idempotent — re-running with --opencode reports current" do
      fs = InMemoryFS.new
      run_init(fs, Muninn::Init::Options.new(opencode: true))
      plugin_before = fs.files["/repo/.opencode/plugins/muninn.js"]
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(opencode: true))
      stdout.should contain("current  .opencode/plugins/muninn.js")
      fs.files["/repo/.opencode/plugins/muninn.js"].should eq(plugin_before)
    end

    it "reports would-create under --dry-run without writing" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, Muninn::Init::Options.new(opencode: true, dry_run: true))
      stdout.should contain("would create .opencode/plugins/muninn.js")
      fs.files.has_key?("/repo/.opencode/plugins/muninn.js").should be_false
    end

    it "scaffolds both Claude and OpenCode artefacts simultaneously" do
      fs = InMemoryFS.new
      run_init(fs, Muninn::Init::Options.new(opencode: true))
      fs.files.has_key?("/repo/.claude/settings.json").should be_true
      fs.files.has_key?("/repo/.opencode/plugins/muninn.js").should be_true
    end
  end

  describe ".gitignore merge" do
    it "appends the cache entry when missing, adding a separating newline" do
      fs = InMemoryFS.new({GITIGNORE => "/bin\n/lib"})
      run_init(fs)
      fs.files[GITIGNORE].should eq("/bin\n/lib\n.cache/muninn/\n")
    end

    it "leaves the file unchanged when the entry is already present" do
      existing = "/bin\n.cache/muninn/\n"
      fs = InMemoryFS.new({GITIGNORE => existing})
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .gitignore")
      fs.files[GITIGNORE].should eq(existing)
    end
  end
end
