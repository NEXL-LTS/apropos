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
      ["build", "src/agent_apropos.cr", "-o", binary],
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

  # Gemini CLI wires both `hook pre` and `hook post` onto its AfterTool event
  # (its BeforeTool output schema cannot inject context — see init.cr), and its
  # write_file/replace tools happen to use the exact argument names Claude's
  # Write/Edit do. These fixtures are real captures of that shape (see
  # spec/fixtures/hook_payloads/), proving the binary needs no Gemini-specific
  # code, not just the injected-IO unit specs.
  it "handles a Gemini CLI write_file AfterTool payload with no tool-specific code" do
    dir = File.tempname("apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/db.md"),
        "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nWrap writes in a transaction.\n")

      payload = File.read("spec/fixtures/hook_payloads/gemini_after_tool_write_file.json")
        .gsub("db/migrate/001_create.cr", File.join(dir, "db/migrate/001_create.cr"))

      code, output = run_hook(binary, ["hook", "post", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Wrap writes in a transaction.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "handles a Gemini CLI replace AfterTool payload with no tool-specific code" do
    dir = File.tempname("apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = File.read("spec/fixtures/hook_payloads/gemini_after_tool_replace.json")
        .gsub("app/jobs/mailer_job.cr", File.join(dir, "app/jobs/mailer_job.cr"))

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Keep jobs idempotent.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
