require "../spec_helper"

private NOW = Time.utc(2026, 7, 16, 12, 0, 0)

private A_PATH      = "/repo/docs/conventions/a.md"
private DB_PATH     = "/repo/docs/conventions/db.md"
private MODELS_PATH = "/repo/docs/conventions/models.md"

private A_DOC      = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"
private DB_DOC     = "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nUse transactions carefully.\n"
private MODELS_DOC = "---\npaths: [\"app/**\"]\ncontents: ['\\bupdate_all\\b']\n---\n# Models\n\nAvoid update_all.\n"

# A filesystem that rejects writes, so the persist-index and dedup-save paths
# must degrade gracefully.
private class ReadOnlyFS < InMemoryFS
  def write(path : String, content : String) : Nil
    raise "read-only filesystem"
  end
end

# A filesystem that raises on every read, forcing an internal error so the
# fail-open + verbose-logging paths are exercised. The raises are guarded by an
# always-true flag so the compiler still infers String/String? (an unconditional
# raise would be NoReturn and poison type inference in the modules under test).
private class ExplodingFS < Apropos::Filesystem
  getter appended = [] of {String, String}

  def initialize(@append_raises : Bool = false, @raise_reads : Bool = true)
  end

  def glob(base : Path, pattern : String) : Array(String)
    [] of String
  end

  def read(path : String) : String
    raise "boom" if @raise_reads
    ""
  end

  def read?(path : String) : String?
    raise "boom" if @raise_reads
    ""
  end

  def write(path : String, content : String) : Nil
  end

  def append(path : String, content : String) : Nil
    raise "log boom" if @append_raises
    @appended << {path, content}
  end

  def remove(path : String) : Nil
  end

  def exists?(path : String) : Bool
    false
  end

  def symlink(target : String, link_path : String) : Nil
  end
end

private def pre_json(file_path : String, session_id : String? = "s", cwd : String? = "/repo") : String
  {session_id: session_id, tool_name: "Edit", cwd: cwd, tool_input: {file_path: file_path}}.to_json
end

private def write_json(file_path : String, content : String, session_id : String? = "s") : String
  {session_id: session_id, tool_name: "Write", cwd: "/repo",
   tool_input: {file_path: file_path, content: content}}.to_json
end

private def invoke(event : Symbol, input : String, fs : Apropos::Filesystem,
                   override : String? = "/repo", now : Time = NOW, verbose : Bool = false) : {Int32, String}
  stdout = IO::Memory.new
  reader = IO::Memory.new(input)
  code =
    if event == :pre
      Apropos::Hook.pre(reader, stdout, fs, now, override, verbose)
    else
      Apropos::Hook.post(reader, stdout, fs, now, override, verbose)
    end
  {code, stdout.to_s}
end

describe Apropos::Hook do
  describe ".pre" do
    it "injects a matching Layer 2 rule before the edit" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC})
      code, stdout = invoke(:pre, pre_json("/repo/src/app.cr"), fs)

      code.should eq(0)
      stdout.should contain(%("hookEventName":"PreToolUse"))
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Body of A.")
      fs.files.has_key?("/repo/.cache/apropos/index.json").should be_true
      fs.files.has_key?("/repo/.cache/apropos/sessions/s.json").should be_true
    end

    it "injects a rule at most once per session" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, pre_json("src/app.cr"), fs)[1]
        .should contain("Convention (docs/conventions/a.md):")

      code, stdout = invoke(:pre, pre_json("src/other.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing when no Layer 2 rule matches the path" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("docs/readme.md"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing on malformed stdin (fail open)" do
      code, stdout = invoke(:pre, "{ not json", InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing when the payload carries no file_path" do
      code, stdout = invoke(:pre, %({"session_id":"s","tool_input":{}}), InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    it "resolves the repo root from the payload cwd when no override is given" do
      code, stdout = invoke(:pre, pre_json("src/app.cr", cwd: Dir.current), InMemoryFS.new, override: nil)
      code.should eq(0)
      stdout.should be_empty
    end

    it "falls back to the process directory when the payload has no cwd" do
      code, stdout = invoke(:pre, pre_json("src/app.cr", cwd: nil), InMemoryFS.new, override: nil)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing when no repo root can be resolved" do
      input = pre_json("src/app.cr", cwd: File.tempname("apropos-norepo"))
      code, stdout = invoke(:pre, input, InMemoryFS.new, override: nil)
      code.should eq(0)
      stdout.should be_empty
    end

    it "uses an existing index and emits nothing when the source doc is unreadable" do
      index = Apropos::Index.build([Apropos::Convention.parse("docs/conventions/a.md", A_DOC)])
      fs = InMemoryFS.new({"/repo/.cache/apropos/index.json" => index.to_document})
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "summarizes matched rules that exceed the character cap" do
      big = "First paragraph.\n\n" + ("x" * 11_000)
      fs = InMemoryFS.new({A_PATH => "---\npaths: [\"src/**\"]\n---\n#{big}\n"})
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)

      code.should eq(0)
      stdout.should contain("summarized to fit")
      stdout.should contain("First paragraph.")
      stdout.should contain("Read the full rule in docs/conventions/a.md")
    end

    it "still injects when the cache is unwritable and dedup is unavailable" do
      fs = ReadOnlyFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("src/app.cr", session_id: nil), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      fs.files.has_key?("/repo/.cache/apropos/index.json").should be_false
    end

    it "fails open and stays silent on an internal error" do
      fs = ExplodingFS.new
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.appended.should be_empty
    end

    it "logs the failure under the override root when verbose" do
      fs = ExplodingFS.new
      code, _ = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      code.should eq(0)
      fs.appended.map(&.first).should eq(["/repo/.cache/apropos/log"])
    end

    it "logs to the process directory when verbose with no override" do
      fs = ExplodingFS.new
      invoke(:pre, pre_json("src/app.cr", cwd: Dir.current), fs, override: nil, verbose: true)
      fs.appended.first.first.should eq(File.join(Dir.current, ".cache", "apropos", "log"))
    end

    it "swallows a logging failure (best-effort log)" do
      fs = ExplodingFS.new(append_raises: true)
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      code.should eq(0)
      stdout.should be_empty
    end
  end

  describe ".post" do
    it "injects a repo-wide Layer 3 rule when written content matches" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC})
      code, stdout = invoke(:post, write_json("lib/x.cr", "db.transaction do"), fs)

      code.should eq(0)
      stdout.should contain(%("hookEventName":"PostToolUse"))
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "injects a path-scoped Layer 3 rule only when path and content both match" do
      fs = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      invoke(:post, write_json("app/models/u.cr", "User.update_all(x: 1)"), fs)[1]
        .should contain("Convention (docs/conventions/models.md):")

      other = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      code, stdout = invoke(:post, write_json("scripts/one_off.cr", "User.update_all(x: 1)"), other)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing when no Layer 3 content matches" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      code, stdout = invoke(:post, write_json("lib/x.cr", "just some code"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "reads the file from disk when the payload has no content field" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, "/repo/lib/x.cr" => "wrap in a transaction here"})
      input = %({"session_id":"s","tool_name":"Write","cwd":"/repo","tool_input":{"file_path":"lib/x.cr"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "emits nothing when there is neither content nor a file to read" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","tool_name":"Write","cwd":"/repo","tool_input":{"file_path":"lib/gone.cr"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "matches against every new_string of a batch edit" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","tool_name":"MultiEdit","cwd":"/repo","tool_input":) +
              %({"file_path":"lib/x.cr","edits":[{"new_string":"noop"},{"new_string":"begin transaction"}]}})
      _, stdout = invoke(:post, input, fs)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end
  end

  # Gemini CLI wires both `hook pre` and `hook post` onto its single
  # `AfterTool` event (its `BeforeTool` output schema cannot inject context —
  # see init.cr). Its `write_file`/`replace` tools use the exact same
  # `file_path`/`content`/`old_string`/`new_string` argument names Claude's
  # `Write`/`Edit` do, so this runtime needs no Gemini-specific code — these
  # cases lock that finding in against a regression.
  describe "Gemini CLI payload shapes (no tool_name gating)" do
    it "matches a Layer 2 rule from a write_file AfterTool payload" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      input = %({"session_id":"s","hook_event_name":"AfterTool","tool_name":"write_file",) +
              %("cwd":"/repo","tool_input":{"file_path":"src/app.cr","content":"puts 1"}})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "matches a Layer 3 rule from a replace AfterTool payload" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","hook_event_name":"AfterTool","tool_name":"replace",) +
              %("cwd":"/repo","tool_input":{"file_path":"lib/x.cr","old_string":"noop",) +
              %("new_string":"db.transaction do"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end
  end
end
