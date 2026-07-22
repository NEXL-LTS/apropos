require "../spec_helper"
require "file_utils"

# End-to-end M5 lifecycle against the built binary: init a fresh repo, generate,
# then lint clean, doctor, and help — the one place the CLI wiring for these
# commands is exercised as a real subprocess. The command logic is unit-tested
# behind injected IO; this proves the entry glue and process boundary work.
private def run_apropos(binary : String, args : Array(String)) : {Int32, String}
  stdout = IO::Memory.new
  status = Process.run(binary, args, input: IO::Memory.new, output: stdout, error: stdout)
  {status.exit_code, stdout.to_s}
end

describe "apropos init/lint/doctor/help (binary)" do
  binary = File.join(Dir.tempdir, "apropos-lifecycle-#{Process.pid}")

  Spec.before_suite do
    status = Process.run(
      "crystal", ["build", "src/agent_apropos.cr", "-o", binary],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit
    )
    raise "failed to build apropos binary for integration specs" unless status.success?
  end

  Spec.after_suite do
    File.delete?(binary)
  end

  it "bootstraps a repo with --tool opencode --tool claude and doctor shows opencode line" do
    dir = File.tempname("apropos-lifecycle-opencode")
    begin
      Dir.mkdir_p(dir)

      code, stdout = run_apropos(binary, ["init", "--tool", "opencode", "--tool", "claude", "--repo-root", dir])
      code.should eq(0)
      stdout.should contain(".opencode/plugins/apropos.js")
      File.exists?(File.join(dir, ".opencode/plugins/apropos.js")).should be_true
      File.exists?(File.join(dir, ".claude/settings.json")).should be_true

      _, stdout = run_apropos(binary, ["doctor", "--repo-root", dir])
      stdout.should contain("opencode:")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "bootstraps a repo with --tool gemini and doctor shows the gemini line" do
    dir = File.tempname("apropos-lifecycle-gemini")
    begin
      Dir.mkdir_p(dir)

      code, stdout = run_apropos(binary, ["init", "--tool", "gemini", "--repo-root", dir])
      code.should eq(0)
      stdout.should contain(".gemini/settings.json")
      File.exists?(File.join(dir, ".gemini/settings.json")).should be_true
      File.exists?(File.join(dir, ".claude/settings.json")).should be_false

      settings = File.read(File.join(dir, ".gemini/settings.json"))
      settings.should contain("AfterTool")
      settings.should contain("apropos hook pre")
      settings.should contain("apropos hook post")

      # `gemini` is genuinely on PATH in this devcontainer (npm-installed), so
      # doctor's advisory check actually runs rather than skipping — confirming
      # the wiring `init` just wrote is itself well-formed.
      _, stdout = run_apropos(binary, ["doctor", "--repo-root", dir])
      stdout.should contain("gemini:")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "bootstraps a repo and lints it clean" do
    dir = File.tempname("apropos-lifecycle-repo")
    begin
      Dir.mkdir_p(dir)

      code, stdout = run_apropos(binary, ["init", "--example", "--tool", "claude", "--repo-root", dir])
      code.should eq(0)
      stdout.should contain("created  .claude/settings.json")
      File.exists?(File.join(dir, "docs/conventions/README.md")).should be_true

      run_apropos(binary, ["generate", "--repo-root", dir])

      code, stdout = run_apropos(binary, ["lint", "--repo-root", dir])
      code.should eq(0)
      stdout.should contain("lint: clean")

      _, stdout = run_apropos(binary, ["doctor", "--repo-root", dir])
      stdout.should contain("doctor:")
      stdout.should contain("index: fresh")

      code, stdout = run_apropos(binary, ["help"])
      code.should eq(0)
      stdout.should contain("What apropos is")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
