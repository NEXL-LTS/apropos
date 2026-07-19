require "../spec_helper"

private ROOT          = Path["/repo"]
private SETTINGS_PATH = "/repo/.claude/settings.json"
private INDEX_PATH    = "/repo/.cache/apropos/index.json"
private DOC_PATH      = "/repo/docs/conventions/a.md"
private DOC_TEXT      = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody.\n"

private FULL_SETTINGS = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"apropos hook pre"}]}],) +
                        %("PostToolUse":[{"hooks":[{"type":"command","command":"apropos hook post"}]}]}})

# A configurable Environment: `present` maps a command to its resolved path;
# `outputs` maps a command to its captured `--version` stdout.
private class FakeEnv < Apropos::Environment
  def initialize(@present : Hash(String, String) = {} of String => String,
                 @outputs : Hash(String, String?) = {} of String => String?)
  end

  def which(command : String) : String?
    @present[command]?
  end

  def run_capture(command : String, args : Array(String)) : String?
    @outputs[command]?
  end
end

# Rejects writes so the cache-writability check can fail.
private class ReadOnlyFS < InMemoryFS
  def write(path : String, content : String) : Nil
    raise "read-only filesystem"
  end
end

private def index_for(text : String) : String
  Apropos::Index.build([Apropos::Convention.parse("docs/conventions/a.md", text)]).to_document
end

private def run_doctor(fs : Apropos::Filesystem, env : Apropos::Environment) : {Int32, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Apropos::Doctor.run(ROOT, fs, env, stdout, stderr)
  {code, stdout.to_s}
end

describe Apropos::Doctor do
  it "passes cleanly when everything is wired" do
    fs = InMemoryFS.new({
      SETTINGS_PATH => FULL_SETTINGS,
      DOC_PATH      => DOC_TEXT,
      INDEX_PATH    => index_for(DOC_TEXT),
    })
    env = FakeEnv.new(
      present: {"apropos" => "/usr/bin/apropos", "claude" => "/usr/bin/claude"},
      outputs: {"claude" => "2.1.0 (Claude Code)".as(String?)})
    code, stdout = run_doctor(fs, env)
    code.should eq(0)
    stdout.should contain("ok    hooks: PreToolUse and PostToolUse call apropos")
    stdout.should contain("ok    apropos: on PATH at /usr/bin/apropos")
    stdout.should contain("supports PreToolUse additionalContext")
    stdout.should contain("ok    index: fresh")
    stdout.should contain("ok    cache: .cache/apropos is writable")
    stdout.should contain("doctor: 0 failure(s), 0 warning(s)")
  end

  describe "hooks check" do
    it "fails when settings.json is absent" do
      code, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      code.should eq(1)
      stdout.should contain("fail  hooks: .claude/settings.json not found")
    end

    it "warns when settings.json is not valid JSON" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("warn  hooks: .claude/settings.json is not valid JSON")
    end

    it "warns when only one event calls apropos" do
      only_post = %({"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"apropos hook post"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => only_post})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("only PostToolUse calls apropos")
    end

    it "fails when no apropos hooks are wired" do
      foreign = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]},"weird"]}})
      fs = InMemoryFS.new({SETTINGS_PATH => foreign})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("fail  hooks: no apropos hooks wired")
    end

    it "fails when settings has no hooks section at all" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{}"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("no apropos hooks wired")
    end

    it "fails when an event value is not an array" do
      fs = InMemoryFS.new({SETTINGS_PATH => %({"hooks":{"PreToolUse":"weird"}})})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("no apropos hooks wired")
    end

    it "ignores a hook entry with no command field" do
      no_cmd = %({"hooks":{"PostToolUse":[{"hooks":[{"type":"command"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => no_cmd})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("no apropos hooks wired")
    end
  end

  describe "apropos check" do
    it "warns when apropos is not on PATH" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("warn  apropos: not found on PATH")
    end
  end

  describe "claude check" do
    it "is ok (skipped) when claude is not on PATH" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("claude: not on PATH; skipped")
    end

    it "warns when claude --version cannot be run" do
      env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"})
      _, stdout = run_doctor(InMemoryFS.new, env)
      stdout.should contain("could not run `claude --version`")
    end

    it "warns when the version cannot be parsed" do
      env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
        outputs: {"claude" => "unknown".as(String?)})
      _, stdout = run_doctor(InMemoryFS.new, env)
      stdout.should contain("could not parse a version")
    end

    it "warns when the version is below the minimum" do
      env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
        outputs: {"claude" => "0.9.0".as(String?)})
      _, stdout = run_doctor(InMemoryFS.new, env)
      stdout.should contain("may lack PreToolUse additionalContext")
    end
  end

  describe "opencode check" do
    it "is ok (skipped) when opencode is not on PATH" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("opencode: not on PATH; skipped plugin check")
    end

    it "warns when opencode is on PATH but the plugin is absent" do
      env = FakeEnv.new(present: {"opencode" => "/usr/bin/opencode"})
      _, stdout = run_doctor(InMemoryFS.new, env)
      stdout.should contain("warn  opencode: plugin absent; run `apropos init --tool opencode`")
    end

    it "is ok when opencode is on PATH and the plugin is present" do
      env = FakeEnv.new(present: {"opencode" => "/usr/bin/opencode"})
      fs = InMemoryFS.new({"/repo/.opencode/plugins/apropos.js" => "// plugin"})
      _, stdout = run_doctor(fs, env)
      stdout.should contain("ok    opencode: plugin wired")
    end
  end

  describe "gemini check" do
    it "is ok (skipped) when gemini is not on PATH" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("gemini: not on PATH; skipped hook check")
    end

    it "warns when gemini is on PATH but settings.json is absent" do
      env = FakeEnv.new(present: {"gemini" => "/usr/bin/gemini"})
      _, stdout = run_doctor(InMemoryFS.new, env)
      stdout.should contain("warn  gemini: .gemini/settings.json absent")
    end

    it "warns when settings.json is not valid JSON" do
      env = FakeEnv.new(present: {"gemini" => "/usr/bin/gemini"})
      fs = InMemoryFS.new({"/repo/.gemini/settings.json" => "{not json"})
      _, stdout = run_doctor(fs, env)
      stdout.should contain("gemini: .gemini/settings.json is not valid JSON")
    end

    it "warns when the AfterTool hook is absent" do
      env = FakeEnv.new(present: {"gemini" => "/usr/bin/gemini"})
      fs = InMemoryFS.new({"/repo/.gemini/settings.json" => %({"hooks":{}})})
      _, stdout = run_doctor(fs, env)
      stdout.should contain("warn  gemini: AfterTool hook absent")
    end

    it "warns when only one of pre/post is wired under AfterTool" do
      env = FakeEnv.new(present: {"gemini" => "/usr/bin/gemini"})
      only_pre = %({"hooks":{"AfterTool":[{"hooks":[{"type":"command","command":"apropos hook pre"}]}]}})
      fs = InMemoryFS.new({"/repo/.gemini/settings.json" => only_pre})
      _, stdout = run_doctor(fs, env)
      stdout.should contain("warn  gemini: AfterTool hook absent")
    end

    it "is ok when gemini is on PATH and both hooks are wired" do
      env = FakeEnv.new(present: {"gemini" => "/usr/bin/gemini"})
      wired = %({"hooks":{"AfterTool":[{"hooks":[) +
              %({"type":"command","command":"apropos hook pre"},) +
              %({"type":"command","command":"apropos hook post"}]}]}})
      fs = InMemoryFS.new({"/repo/.gemini/settings.json" => wired})
      _, stdout = run_doctor(fs, env)
      stdout.should contain("ok    gemini: AfterTool hook wired")
    end
  end

  describe "index check" do
    it "warns when the index is missing" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("index: not built")
    end

    it "warns when the index is unreadable" do
      fs = InMemoryFS.new({INDEX_PATH => "garbage"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("index: unreadable")
    end

    it "warns when a malformed doc blocks freshness evaluation" do
      fs = InMemoryFS.new({
        INDEX_PATH => index_for(DOC_TEXT),
        DOC_PATH   => "---\npaths: [\n---\nx\n", # malformed → walk raises
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("cannot evaluate freshness")
    end

    it "warns when the index is stale" do
      fs = InMemoryFS.new({
        INDEX_PATH => index_for(DOC_TEXT),
        DOC_PATH   => DOC_TEXT + "\nmore\n", # content changed → hash differs
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("index: stale")
    end
  end

  describe "cache check" do
    it "fails when the cache is not writable" do
      fs = ReadOnlyFS.new({SETTINGS_PATH => FULL_SETTINGS})
      code, stdout = run_doctor(fs, FakeEnv.new)
      code.should eq(1)
      stdout.should contain("fail  cache: .cache/apropos is not writable")
    end
  end
end
