require "../spec_helper"
require "file_utils"

private def run(args : Array(String), stdin : String = "")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Muninn::CLI.run(args, stdout, stderr, IO::Memory.new(stdin))
  {code, stdout.to_s, stderr.to_s}
end

# A throwaway repo with one Layer 2 doc and one skill doc; yields its path.
private def with_fixture_repo(git : Bool = false, &)
  dir = File.tempname("muninn-cli")
  begin
    Dir.mkdir_p(File.join(dir, "docs/conventions/workflows"))
    Dir.mkdir_p(File.join(dir, ".git")) if git
    File.write(File.join(dir, "docs/conventions/a.md"), "---\npaths: [\"src/**\"]\n---\nA\n")
    File.write(File.join(dir, "docs/conventions/workflows/foo.md"),
      "---\nskill: true\ndescription: \"Use when foo\"\n---\nbody\n")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def in_dir(dir : String, &)
  original = Dir.current
  Dir.cd(dir)
  begin
    yield
  ensure
    Dir.cd(original)
  end
end

describe Muninn::CLI do
  describe "help" do
    it "prints usage and exits 0 with no args" do
      code, out, err = run([] of String)
      code.should eq(0)
      out.should contain("Usage: muninn")
      err.should be_empty
    end

    it "prints usage for --help, -h, and help" do
      %w[--help -h help].each do |flag|
        code, out, _ = run([flag])
        code.should eq(0)
        out.should contain("Usage: muninn")
      end
    end
  end

  describe "version" do
    it "prints the version for --version and version" do
      %w[--version version].each do |flag|
        code, out, _ = run([flag])
        code.should eq(0)
        out.should contain("muninn #{Muninn::VERSION}")
      end
    end
  end

  describe "unknown command" do
    it "reports the error on stderr and exits 1" do
      code, out, err = run(["frobnicate"])
      code.should eq(1)
      out.should be_empty
      err.should contain("unknown command 'frobnicate'")
    end
  end

  describe "generate" do
    it "builds the index and wrappers against an explicit --repo-root" do
      with_fixture_repo do |dir|
        code, out, err = run(["generate", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        out.should contain("index: rebuilt")
        File.exists?(File.join(dir, ".cache/muninn/index.json")).should be_true
        File.exists?(File.join(dir, ".claude/skills/foo/SKILL.md")).should be_true
      end
    end

    it "runs --check green right after a generate" do
      with_fixture_repo do |dir|
        run(["generate", "--repo-root", dir])
        code, out, _ = run(["generate", "--check", "--repo-root", dir])
        code.should eq(0)
        out.should contain("up to date")
      end
    end

    it "resolves the repo root from the working directory by default" do
      with_fixture_repo(git: true) do |dir|
        code, out, _ = in_dir(dir) { run(["generate"]) }
        code.should eq(0)
        out.should contain("index: rebuilt")
      end
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["generate"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["generate", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects an unknown option" do
      code, _, err = run(["generate", "--bogus"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end
  end

  describe "hook" do
    it "injects a Layer 2 rule on pre with an explicit repo root" do
      with_fixture_repo do |dir|
        payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                   tool_input: {file_path: File.join(dir, "src/x.cr")}}.to_json
        code, out, err = run(["hook", "pre", "--repo-root", dir], payload)
        code.should eq(0)
        err.should be_empty
        out.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "runs post through the real filesystem and exits 0" do
      with_fixture_repo do |dir|
        payload = {session_id: "s", tool_name: "Write", cwd: dir,
                   tool_input: {file_path: File.join(dir, "src/x.cr"), content: "code"}}.to_json
        code, out, _ = run(["hook", "post", "--repo-root", dir], payload)
        code.should eq(0)
        out.should be_empty
      end
    end

    it "resolves the repo root from the payload cwd by default" do
      with_fixture_repo(git: true) do |dir|
        payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                   tool_input: {file_path: "src/x.cr"}}.to_json
        code, out, _ = run(["hook", "pre"], payload)
        code.should eq(0)
        out.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "exits 0 on an unknown hook subcommand (fail open)" do
      code, out, err = run(["hook", "frobnicate"])
      code.should eq(0)
      out.should be_empty
      err.should be_empty
    end
  end
end
