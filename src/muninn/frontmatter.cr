require "yaml"
require "./errors"

module Muninn
  # Parsed YAML frontmatter from a convention doc (PRD §5.2). This layer
  # validates the *shape* of the frontmatter only — the types of the known
  # keys. Semantic rules (e.g. `skill: true` requires a `description` that
  # starts with "Use when") are the linter's job (PRD §5.8), not this parser's,
  # so the model stays reusable by every command.
  struct Frontmatter
    # Raised when a frontmatter block is structurally invalid: malformed YAML,
    # a non-mapping top level, a wrong-typed known key, or an unterminated
    # fence. Distinct from lint-level policy violations.
    class Error < Muninn::Error
    end

    KNOWN_KEYS = ["paths", "contents", "skill", "description"]

    # A doc opens with a `---` fence on its own line (optional trailing spaces,
    # optional CR). The body begins after the matching closing fence line.
    OPEN_FENCE  = /\A---[^\S\r\n]*\r?\n/
    CLOSE_FENCE = /^---[^\S\r\n]*(?:\r?\n|\z)/m

    getter paths : Array(String)
    getter contents : Array(String)
    getter? skill : Bool
    getter description : String?
    getter unknown_keys : Array(String)

    def initialize(
      @paths = [] of String,
      @contents = [] of String,
      @skill = false,
      @description = nil,
      @unknown_keys = [] of String,
    )
    end

    # A doc with neither a path nor a content trigger and no skill flag is
    # reference-only: reachable by link, never injected (PRD §5.2).
    def reference_only? : Bool
      paths.empty? && contents.empty? && !skill?
    end

    # Split raw doc text into `{frontmatter, body}`. A doc without a leading
    # fence has no frontmatter and its whole text is the body. Body bytes are
    # preserved exactly (byte-stable output is a hard requirement — PRD §6).
    def self.split(text : String) : {Frontmatter?, String}
      open = text.match(OPEN_FENCE)
      return {nil, text} unless open

      after_open = text[open.end..]
      close = after_open.match(CLOSE_FENCE)
      raise Error.new("unterminated frontmatter block") unless close

      yaml = after_open[0, close.begin]
      body = after_open[close.end..]
      {parse(yaml), body}
    end

    # Parse the YAML between the fences into a validated Frontmatter.
    def self.parse(yaml : String) : Frontmatter
      any =
        begin
          YAML.parse(yaml)
        rescue ex : YAML::ParseException
          raise Error.new("invalid YAML frontmatter: #{ex.message}")
        end

      # Blank or comment-only frontmatter parses to nil → empty (reference-only).
      return new if any.raw.nil?

      hash = any.as_h?
      raise Error.new("frontmatter must be a mapping") if hash.nil?

      unknown = hash.keys.compact_map(&.as_s?).reject { |key| KNOWN_KEYS.includes?(key) }.sort!
      new(
        paths: string_list(hash, "paths"),
        contents: string_list(hash, "contents"),
        skill: boolean(hash, "skill"),
        description: string(hash, "description"),
        unknown_keys: unknown,
      )
    end

    # Fetch a key, treating an explicit YAML null the same as an absent key.
    private def self.fetch(hash, key)
      value = hash[key]?
      return nil if value.nil? || value.raw.nil?
      value
    end

    private def self.string_list(hash, key) : Array(String)
      value = fetch(hash, key)
      return [] of String if value.nil?
      array = value.as_a?
      raise Error.new("`#{key}` must be a list of strings") if array.nil?
      array.map do |item|
        item.as_s? || raise Error.new("`#{key}` entries must be strings")
      end
    end

    private def self.boolean(hash, key) : Bool
      value = fetch(hash, key)
      return false if value.nil?
      bool = value.as_bool?
      raise Error.new("`#{key}` must be a boolean") if bool.nil?
      bool
    end

    private def self.string(hash, key) : String?
      value = fetch(hash, key)
      return nil if value.nil?
      str = value.as_s?
      raise Error.new("`#{key}` must be a string") if str.nil?
      str
    end
  end
end
