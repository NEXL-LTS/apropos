module Muninn
  # Resolve the repository root by walking up from `start` to the nearest
  # directory containing `.git`. Returns nil if the filesystem root
  # is reached without finding one. This is the CLI default when `--repo-root`
  # is not given; it is the one place path discovery touches disk directly.
  def self.find_repo_root(start : Path) : Path?
    current = start.expand
    loop do
      return current if File.exists?(current.join(".git").to_s)
      parent = current.parent
      return nil if parent == current
      current = parent
    end
  end
end
