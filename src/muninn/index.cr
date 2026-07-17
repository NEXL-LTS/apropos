require "json"
require "./conventions"

module Muninn
  # The trigger index: a compiled, serialized view of every
  # convention doc so the hot hook path never parses YAML. Persisted as
  # deterministic JSON at `.cache/muninn/index.json` and rebuilt only when a
  # doc's content hash changes (or the index is absent / a different schema
  # version). This module owns build, (de)serialization, and the staleness
  # decision — a mutation-testing target.
  struct Index
    # Bump when the entry shape changes; a mismatch forces a rebuild so an old
    # index is never trusted after an upgrade.
    SCHEMA_VERSION = 1

    # One doc's compiled metadata. Regexes are stored as their sources (globs
    # and PCRE2 strings) since a compiled `Regex` cannot be serialized; the
    # matcher recompiles on use.
    struct Entry
      include JSON::Serializable

      getter path : String
      getter hash : String
      getter? layer2 : Bool
      getter? layer3 : Bool
      getter? skill : Bool
      getter paths : Array(String)
      getter contents : Array(String)
      getter description : String?

      def initialize(
        @path : String,
        @hash : String,
        @layer2 : Bool,
        @layer3 : Bool,
        @skill : Bool,
        @paths : Array(String),
        @contents : Array(String),
        @description : String?,
      )
      end

      def self.from(convention : Convention) : Entry
        fm = convention.frontmatter
        new(
          path: convention.path,
          hash: convention.hash,
          layer2: convention.layer2?,
          layer3: convention.layer3?,
          skill: convention.skill?,
          paths: fm.paths,
          contents: fm.contents,
          description: fm.description,
        )
      end
    end

    include JSON::Serializable

    @[JSON::Field(key: "schema_version")]
    getter schema_version : Int32
    getter docs : Array(Entry)

    def initialize(@docs : Array(Entry), @schema_version : Int32 = SCHEMA_VERSION)
    end

    # Build a fresh index from parsed conventions. Doc order is preserved (the
    # walk is already sorted), so serialization is byte-stable.
    def self.build(conventions : Array(Convention)) : Index
      new(conventions.map { |convention| Entry.from(convention) })
    end

    # Parse a stored index. Returns nil on malformed JSON or a schema-version
    # mismatch, so callers treat a corrupt or outdated index identically to a
    # missing one (rebuild).
    def self.load(json : String) : Index?
      index = from_json(json)
      return nil unless index.schema_version == SCHEMA_VERSION
      index
    rescue JSON::ParseException
      nil
    end

    # Does this stored index already reflect exactly these docs — same set of
    # paths, each with an unchanged content hash? Staleness is defined purely by
    # the doc set and content hashes; a difference means rebuild.
    def covers?(conventions : Array(Convention)) : Bool
      docs.map { |entry| {entry.path, entry.hash} } ==
        conventions.map { |convention| {convention.path, convention.hash} }
    end

    # Deterministic on-disk form: pretty JSON, LF endings, single trailing
    # newline. A prerequisite for stable diffs and re-parsing.
    def to_document : String
      String.build do |io|
        to_pretty_json(io)
        io << '\n'
      end
    end
  end
end
