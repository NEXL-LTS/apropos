require "../spec_helper"
require "file_utils"

# End-to-end M5 lifecycle against the built binary: init a fresh repo, generate,
# then lint clean, doctor, and help — the one place the CLI wiring for these
# commands is exercised as a real subprocess. The command logic is unit-tested
# behind injected IO; this proves the entry glue and process boundary work.
private def run_muninn(binary : String, args : Array(String)) : {Int32, String}
  stdout = IO::Memory.new
  status = Process.run(binary, args, input: IO::Memory.new, output: stdout, error: stdout)
  {status.exit_code, stdout.to_s}
end

describe "muninn init/lint/doctor/help (binary)" do
  binary = File.join(Dir.tempdir, "muninn-lifecycle-#{Process.pid}")

  Spec.before_suite do
    status = Process.run(
      "crystal", ["build", "src/muninn.cr", "-o", binary],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit
    )
    raise "failed to build muninn binary for integration specs" unless status.success?
  end

  Spec.after_suite do
    File.delete?(binary)
  end

  it "bootstraps a repo and lints it clean" do
    dir = File.tempname("muninn-lifecycle-repo")
    begin
      Dir.mkdir_p(dir)

      code, stdout = run_muninn(binary, ["init", "--example", "--repo-root", dir])
      code.should eq(0)
      stdout.should contain("created  .claude/settings.json")
      File.exists?(File.join(dir, "docs/conventions/README.md")).should be_true

      run_muninn(binary, ["generate", "--repo-root", dir])

      code, stdout = run_muninn(binary, ["lint", "--repo-root", dir])
      code.should eq(0)
      stdout.should contain("lint: clean")

      _, stdout = run_muninn(binary, ["doctor", "--repo-root", dir])
      stdout.should contain("doctor:")
      stdout.should contain("index: fresh")

      code, stdout = run_muninn(binary, ["help"])
      code.should eq(0)
      stdout.should contain("What muninn is")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
