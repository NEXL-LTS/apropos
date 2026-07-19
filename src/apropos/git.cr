require "./errors"

module Apropos
  # The git boundary, used only by `review` — the one command
  # allowed to shell out. Kept to the three primitives review needs so the
  # range-resolution and diff-parsing logic can be unit-tested against a fake,
  # and `Real` stays a thin wrapper around the `git` process.
  abstract class Git
    # Raised when a git invocation fails or a default branch cannot be resolved.
    # A `Apropos::Error`, so `review` fails closed (non-zero) like any CI command.
    class Error < Apropos::Error
    end

    # The unified diff for `range` (e.g. `origin/main...HEAD`).
    abstract def diff(repo_root : Path, range : String) : String

    # The short name a symbolic ref points at (e.g. `origin/main` for
    # `refs/remotes/origin/HEAD`), or nil when the ref is absent.
    abstract def symbolic_ref(repo_root : Path, name : String) : String?

    # Does `ref` resolve to a commit?
    abstract def ref_exists?(repo_root : Path, ref : String) : Bool

    # The production adapter: the only place the `git` process is spawned.
    class Real < Git
      def diff(repo_root : Path, range : String) : String
        capture(repo_root, ["diff", "--no-color", range])
      end

      def symbolic_ref(repo_root : Path, name : String) : String?
        capture?(repo_root, ["symbolic-ref", "--short", name]).try(&.strip).presence
      end

      def ref_exists?(repo_root : Path, ref : String) : Bool
        !capture?(repo_root, ["rev-parse", "--verify", "--quiet", ref]).nil?
      end

      private def capture(repo_root : Path, args : Array(String)) : String
        capture?(repo_root, args) || raise Error.new("git #{args.join(' ')} failed")
      end

      private def capture?(repo_root : Path, args : Array(String)) : String?
        stdout = IO::Memory.new
        status = Process.run(
          "git", args,
          chdir: repo_root.to_s, output: stdout, error: Process::Redirect::Close
        )
        status.success? ? stdout.to_s : nil
      end
    end
  end
end
