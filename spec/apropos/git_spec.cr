require "../spec_helper"
require "file_utils"

# Exercises `Git::Real` in-process (not through the built binary) against a real
# throwaway repo, so kcov records the adapter's lines. The pure review logic that
# consumes these primitives is covered separately with a fake git (review_spec).
private def git(dir : String, args : Array(String)) : Nil
  status = Process.run("git", args, chdir: dir,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  raise "git #{args.join(' ')} failed" unless status.success?
end

private def commit(dir : String, message : String) : Nil
  git(dir, ["add", "-A"])
  git(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", message])
end

private def with_repo(&)
  dir = File.tempname("apropos-git")
  begin
    Dir.mkdir_p(dir)
    git(dir, ["init", "-b", "main"])
    File.write(File.join(dir, "app.cr"), "line one\n")
    commit(dir, "init")
    git(dir, ["checkout", "-b", "feature"])
    File.write(File.join(dir, "app.cr"), "line one\nadded transaction\n")
    commit(dir, "change")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Apropos::Git::Real do
  it "produces a unified diff for a range" do
    with_repo do |dir|
      diff = Apropos::Git::Real.new.diff(Path[dir], "main...feature")
      diff.should contain("+++ b/app.cr")
      diff.should contain("+added transaction")
    end
  end

  it "reports whether a ref exists" do
    with_repo do |dir|
      real = Apropos::Git::Real.new
      real.ref_exists?(Path[dir], "main").should be_true
      real.ref_exists?(Path[dir], "nope").should be_false
    end
  end

  it "returns nil for an absent symbolic ref (no remote configured)" do
    with_repo do |dir|
      Apropos::Git::Real.new.symbolic_ref(Path[dir], "refs/remotes/origin/HEAD").should be_nil
    end
  end

  it "raises a Git::Error when the git command fails" do
    with_repo do |dir|
      expect_raises(Apropos::Git::Error, "git diff") do
        Apropos::Git::Real.new.diff(Path[dir], "no-such-ref...HEAD")
      end
    end
  end
end
