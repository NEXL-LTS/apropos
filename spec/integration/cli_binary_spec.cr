require "../spec_helper"

# End-to-end coverage of the compiled entry point (src/apropos.cr), which unit
# specs cannot reach because it only runs when the binary is invoked. Builds
# the binary once for the suite, then drives it as a subprocess.
describe "apropos binary" do
  binary = File.join(Dir.tempdir, "apropos-int-#{Process.pid}")

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

  it "prints the version and exits 0" do
    stdout = IO::Memory.new
    status = Process.run(binary, ["--version"], output: stdout)
    status.exit_code.should eq(0)
    stdout.to_s.should contain("apropos #{AgentApropos::VERSION}")
  end

  it "prints usage with no args and exits 0" do
    stdout = IO::Memory.new
    status = Process.run(binary, [] of String, output: stdout)
    status.exit_code.should eq(0)
    stdout.to_s.should contain("Usage: apropos")
  end

  it "errors on an unknown command and exits 1" do
    stderr = IO::Memory.new
    status = Process.run(binary, ["frobnicate"], error: stderr)
    status.exit_code.should eq(1)
    stderr.to_s.should contain("unknown command")
  end
end
