require "../spec_helper"
require "file_utils"

describe "Muninn.find_repo_root" do
  it "returns the directory that contains .git" do
    dir = File.tempname("muninn-root")
    begin
      Dir.mkdir_p(File.join(dir, ".git"))
      root = Muninn.find_repo_root(Path[dir])
      root.should eq(Path[dir].expand)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "walks up from a nested directory to the repo root" do
    dir = File.tempname("muninn-root")
    begin
      Dir.mkdir_p(File.join(dir, ".git"))
      nested = File.join(dir, "a/b/c")
      Dir.mkdir_p(nested)
      Muninn.find_repo_root(Path[nested]).should eq(Path[dir].expand)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns nil when no .git exists up to the filesystem root" do
    dir = File.tempname("muninn-root")
    begin
      Dir.mkdir_p(dir)
      Muninn.find_repo_root(Path[dir]).should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
