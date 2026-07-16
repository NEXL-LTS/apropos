require "../spec_helper"

private def run(args : Array(String))
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = Muninn::CLI.run(args, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
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
end
