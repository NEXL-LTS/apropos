require "../spec_helper"

# The process/PATH adapter is covered in-process (kcov does not measure the
# subprocess integration specs), using `sh` — present on every CI image — and a
# name that cannot resolve.
describe Apropos::Environment::Real do
  env = Apropos::Environment::Real.new

  it "resolves an executable on PATH and returns nil for a missing one" do
    env.which("sh").should_not be_nil
    env.which("apropos-definitely-absent-xyz").should be_nil
  end

  it "captures stdout on success" do
    env.run_capture("sh", ["-c", "printf hello"]).should eq("hello")
  end

  it "returns nil on a non-zero exit" do
    env.run_capture("sh", ["-c", "exit 3"]).should be_nil
  end

  it "returns nil when the command cannot be launched" do
    env.run_capture("apropos-definitely-absent-xyz", [] of String).should be_nil
  end
end
