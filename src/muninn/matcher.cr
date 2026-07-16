require "./errors"

module Muninn
  # The pure matching engine (PRD §5.2): path globs and content regexes. It is
  # deliberately stateless — callers pass patterns and the target — so it is the
  # heaviest mutation-testing target (PRD §8.1) without any I/O to stub.
  #
  # Windows-aware: path matching goes through `File.match?`, which normalizes
  # separators, rather than any hardcoded `/`.
  module Matcher
    extend self

    # Raised when a `contents:` regex source fails to compile (PCRE2). Surfaced
    # by lint (PRD §5.8); on the hook path the caller fails open.
    class Error < Muninn::Error
    end

    # Does `path` match the glob `pattern`? `**` spans any directory depth; a
    # single `*` stays within one segment.
    def path_match?(pattern : String, path : String) : Bool
      File.match?(pattern, path)
    end

    # Does `path` match any of `patterns`?
    def any_path_match?(patterns : Enumerable(String), path : String) : Bool
      patterns.any? { |pattern| path_match?(pattern, path) }
    end

    # Does `content` contain a match for the regex `source`?
    def content_match?(source : String, content : String) : Bool
      compile(source).matches?(content)
    end

    # Does `content` match any of the regex `sources`?
    def any_content_match?(sources : Enumerable(String), content : String) : Bool
      sources.any? { |source| content_match?(source, content) }
    end

    # Is `pattern` a syntactically valid path glob? Surfaced by lint (PRD §5.8).
    # `File.match?` only parses a pattern segment once the candidate path reaches
    # it, so we match against a structurally-identical sample built by neutralizing
    # the glob metacharacters — forcing every segment (including a malformed `[`
    # set) to be parsed.
    def valid_glob?(pattern : String) : Bool
      sample = pattern.gsub(/[*?\[\]!]/, "a")
      File.match?(pattern, sample)
      true
    rescue File::BadPatternError
      false
    end

    # Compile a regex source, translating PCRE2 compile failures into a muninn
    # error so callers get a consistent type to rescue.
    def compile(source : String) : Regex
      Regex.new(source)
    rescue ex : ArgumentError
      raise Error.new("invalid regex #{source.inspect}: #{ex.message}")
    end
  end
end
