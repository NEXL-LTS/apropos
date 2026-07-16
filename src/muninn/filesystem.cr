require "file_utils"

module Muninn
  # The filesystem boundary (PRD §8.2). Logic modules never touch `File`/`Dir`
  # directly — they receive a `Filesystem`, so error and edge paths are
  # unit-testable with a fake and `Real` is the only code that hits disk.
  abstract class Filesystem
    # List files under `base` matching a glob `pattern` (results unsorted;
    # callers sort for determinism — PRD §6).
    abstract def glob(base : Path, pattern : String) : Array(String)

    # Read a file's full contents as a string.
    abstract def read(path : String) : String

    # Read a file if it exists, else nil. Lets callers treat an absent index or
    # skill wrapper the same as an empty one without a separate existence check.
    abstract def read?(path : String) : String?

    # Write `content` to `path`, creating parent directories as needed. Callers
    # supply LF-terminated, byte-stable content (determinism — PRD §6). The write
    # is atomic (temp file + rename) so a concurrent hook never observes a
    # half-written index or session file (PRD §5.7).
    abstract def write(path : String, content : String) : Nil

    # Append `content` to `path`, creating parent directories as needed. Used
    # only for the best-effort `--verbose` hook log (PRD §5.4); never on an
    # artifact whose bytes must be stable.
    abstract def append(path : String, content : String) : Nil

    # Remove a file or directory tree at `path`; a no-op if it does not exist
    # (used to prune orphaned skill wrappers — PRD §5.3).
    abstract def remove(path : String) : Nil

    # The production adapter: the only place `Dir`/`File` are called.
    class Real < Filesystem
      def glob(base : Path, pattern : String) : Array(String)
        Dir.glob(base.join(pattern).to_s)
      end

      def read(path : String) : String
        File.read(path)
      end

      def read?(path : String) : String?
        File.read(path) if File.exists?(path)
      end

      def write(path : String, content : String) : Nil
        target = Path[path]
        dir = target.dirname
        Dir.mkdir_p(dir)
        temp = Path[dir].join(".#{target.basename}.#{Process.pid}.tmp").to_s
        File.write(temp, content)
        File.rename(temp, path)
      end

      def append(path : String, content : String) : Nil
        Dir.mkdir_p(Path[path].dirname)
        File.open(path, "a", &.print(content))
      end

      def remove(path : String) : Nil
        FileUtils.rm_rf(path)
      end
    end
  end
end
