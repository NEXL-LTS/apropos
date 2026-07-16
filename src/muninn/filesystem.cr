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

    # The production adapter: the only place `Dir`/`File` are called.
    class Real < Filesystem
      def glob(base : Path, pattern : String) : Array(String)
        Dir.glob(base.join(pattern).to_s)
      end

      def read(path : String) : String
        File.read(path)
      end
    end
  end
end
