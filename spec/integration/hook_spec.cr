require "../spec_helper"
require "file_utils"

# End-to-end hook runtime against the built binary, driving payloads through
# real stdin (the one place the process boundary and fail-open exit code are
# exercised honestly — unit specs drive the same logic through injected IO).
private def run_hook(binary : String, args : Array(String), payload : String) : {Int32, String}
  stdout = IO::Memory.new
  status = Process.run(binary, args, input: IO::Memory.new(payload), output: stdout)
  {status.exit_code, stdout.to_s}
end

describe "apropos hook (binary)" do
  binary = File.join(Dir.tempdir, "apropos-hook-#{Process.pid}")

  Spec.before_suite do
    status = Process.run(
      "crystal",
      ["build", "src/apropos.cr", "-o", binary],
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    )
    raise "failed to build apropos binary for integration specs" unless status.success?
  end

  Spec.after_suite do
    File.delete?(binary)
  end

  it "injects a Layer 2 rule on PreToolUse and dedupes within a session" do
    dir = File.tempname("apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                 tool_input: {file_path: File.join(dir, "app/jobs/m.cr")}}.to_json

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain(%("hookEventName":"PreToolUse"))
      output.should contain("Keep jobs idempotent.")

      # Second identical call in the same session injects nothing.
      _, second = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      second.should be_empty
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "injects a Layer 3 rule on PostToolUse from written content" do
    dir = File.tempname("apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/db.md"),
        "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nWrap writes in a transaction.\n")

      payload = {session_id: "s", tool_name: "Write", cwd: dir,
                 tool_input: {file_path: File.join(dir, "db/m.cr"), content: "transaction do\nend\n"}}.to_json

      code, output = run_hook(binary, ["hook", "post", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain(%("hookEventName":"PostToolUse"))
      output.should contain("Wrap writes in a transaction.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "fails open (exit 0, no output) on malformed stdin" do
    code, output = run_hook(binary, ["hook", "pre", "--repo-root", "/nonexistent"], "{ not json")
    code.should eq(0)
    output.should be_empty
  end
end
