require "../spec_helper"

private ROOT          = Path["/repo"]
private SETTINGS_PATH = "/repo/.claude/settings.json"
private INDEX_PATH    = "/repo/.cache/muninn/index.json"
private DOC_PATH      = "/repo/docs/conventions/a.md"
private DOC_TEXT      = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody.\n"

private FULL_SETTINGS = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"muninn hook pre"}]}],) +
                        %("PostToolUse":[{"hooks":[{"type":"command","command":"muninn hook post"}]}]}})

# A configurable Environment: `present` maps a command to its resolved path;
# `outputs` maps a command to its captured `--version` stdout.
private class FakeEnv < Muninn::Environment
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
  Muninn::Index.build([Muninn::Convention.parse("docs/conventions/a.md", text)]).to_document
end

private def run_doctor(fs : Muninn::Filesystem, env : Muninn::Environment) : {Int32, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Muninn::Doctor.run(ROOT, fs, env, stdout, stderr)
  {code, stdout.to_s}
end

describe Muninn::Doctor do
  it "passes cleanly when everything is wired" do
    fs = InMemoryFS.new({
      SETTINGS_PATH => FULL_SETTINGS,
      DOC_PATH      => DOC_TEXT,
      INDEX_PATH    => index_for(DOC_TEXT),
    })
    env = FakeEnv.new(
      present: {"muninn" => "/usr/bin/muninn", "claude" => "/usr/bin/claude"},
      outputs: {"claude" => "2.1.0 (Claude Code)".as(String?)})
    code, stdout = run_doctor(fs, env)
    code.should eq(0)
    stdout.should contain("ok    hooks: PreToolUse and PostToolUse call muninn")
    stdout.should contain("ok    muninn: on PATH at /usr/bin/muninn")
    stdout.should contain("supports PreToolUse additionalContext")
    stdout.should contain("ok    index: fresh")
    stdout.should contain("ok    cache: .cache/muninn is writable")
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

    it "warns when only one event calls muninn" do
      only_post = %({"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"muninn hook post"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => only_post})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("only PostToolUse calls muninn")
    end

    it "fails when no muninn hooks are wired" do
      foreign = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]},"weird"]}})
      fs = InMemoryFS.new({SETTINGS_PATH => foreign})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("fail  hooks: no muninn hooks wired")
    end

    it "fails when settings has no hooks section at all" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{}"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("no muninn hooks wired")
    end

    it "fails when an event value is not an array" do
      fs = InMemoryFS.new({SETTINGS_PATH => %({"hooks":{"PreToolUse":"weird"}})})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("no muninn hooks wired")
    end

    it "ignores a hook entry with no command field" do
      no_cmd = %({"hooks":{"PostToolUse":[{"hooks":[{"type":"command"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => no_cmd})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("no muninn hooks wired")
    end
  end

  describe "muninn check" do
    it "warns when muninn is not on PATH" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("warn  muninn: not found on PATH")
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
      stdout.should contain("fail  cache: .cache/muninn is not writable")
    end
  end
end
