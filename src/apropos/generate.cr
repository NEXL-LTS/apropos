require "./conventions"
require "./index"
require "./skills"
require "./filesystem"

module Apropos
  # `apropos generate`: compile `docs/conventions/**` into the trigger
  # index and the committed skill wrappers, and prune orphaned wrappers. `run`
  # writes; `check` never writes and is the CI drift gate. Both fail *closed* —
  # a malformed doc or slug collision exits non-zero — because generate is an
  # authoring/CI command, not the fail-open hook path.
  module Generate
    extend self

    INDEX_RELATIVE  = Path[".cache", "apropos", "index.json"]
    SKILLS_RELATIVE = Path[".claude", "skills"]

    # Rebuild the index when stale and (re)write every skill wrapper, pruning
    # orphans. Progress goes to `stdout`; errors to `stderr`. Returns a process
    # exit code.
    def run(repo_root : Path, fs : Filesystem, stdout : IO, stderr : IO) : Int32
      conventions = Conventions.walk(repo_root, fs)
      wrappers = Skills.wrappers(conventions)

      write_index(repo_root, fs, conventions, stdout)
      write_wrappers(repo_root, fs, wrappers, stdout)
      prune_orphans(repo_root, fs, wrappers.keys, stdout)
      0
    rescue ex : Apropos::Error
      stderr.puts "apropos generate: #{ex.message}"
      1
    end

    # Verify the committed skill wrappers byte-match what the current docs
    # produce and that no orphaned wrappers linger. Writes nothing.
    # Exit 0 when clean, 1 with a drift summary otherwise.
    def check(repo_root : Path, fs : Filesystem, stdout : IO, stderr : IO) : Int32
      conventions = Conventions.walk(repo_root, fs)
      wrappers = Skills.wrappers(conventions)
      drift = [] of String

      wrappers.each do |slug, content|
        actual = fs.read?(wrapper_path(repo_root, slug).to_s)
        if actual.nil?
          drift << "missing: #{wrapper_display(slug)}"
        elsif actual != content
          drift << "stale:   #{wrapper_display(slug)}"
        end
      end

      (existing_slugs(repo_root, fs) - wrappers.keys).each do |slug|
        drift << "orphan:  #{wrapper_display(slug)}"
      end

      report_check(drift, wrappers.size, stdout)
    rescue ex : Apropos::Error
      stderr.puts "apropos generate: #{ex.message}"
      1
    end

    private def report_check(drift : Array(String), count : Int32, stdout : IO) : Int32
      if drift.empty?
        stdout.puts "generate --check: up to date (#{count} skill wrappers)"
        return 0
      end
      stdout.puts "generate --check: drift detected"
      drift.sort.each { |line| stdout.puts "  #{line}" }
      1
    end

    private def write_index(repo_root, fs, conventions, stdout) : Nil
      path = index_path(repo_root).to_s
      existing = fs.read?(path).try { |json| Index.load(json) }
      return if existing && existing.covers?(conventions)
      fs.write(path, Index.build(conventions).to_document)
      stdout.puts "index: rebuilt (#{conventions.size} docs)"
    end

    private def write_wrappers(repo_root, fs, wrappers, stdout) : Nil
      wrappers.keys.sort!.each do |slug|
        content = wrappers[slug]
        path = wrapper_path(repo_root, slug).to_s
        next if fs.read?(path) == content
        fs.write(path, content)
        stdout.puts "skill: wrote #{wrapper_display(slug)}"
      end
    end

    private def prune_orphans(repo_root, fs, keep : Array(String), stdout) : Nil
      (existing_slugs(repo_root, fs) - keep).sort.each do |slug|
        fs.remove(skill_dir(repo_root, slug).to_s)
        stdout.puts "skill: removed orphan #{wrapper_display(slug)}"
      end
    end

    # Slugs of the skill wrappers already on disk, derived from their directory
    # names under `.claude/skills/`.
    private def existing_slugs(repo_root : Path, fs : Filesystem) : Array(String)
      fs.glob(repo_root.join(SKILLS_RELATIVE), "*/SKILL.md").map do |absolute|
        Path[absolute].parent.basename
      end
    end

    private def index_path(repo_root : Path) : Path
      repo_root.join(INDEX_RELATIVE)
    end

    private def skill_dir(repo_root : Path, slug : String) : Path
      repo_root.join(SKILLS_RELATIVE, slug)
    end

    private def wrapper_path(repo_root : Path, slug : String) : Path
      skill_dir(repo_root, slug).join("SKILL.md")
    end

    private def wrapper_display(slug : String) : String
      ".claude/skills/#{slug}/SKILL.md"
    end
  end
end
