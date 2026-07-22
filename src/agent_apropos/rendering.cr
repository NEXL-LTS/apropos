module AgentApropos
  # Shared rendering of matched convention bodies into injectable/pasteable text
  # . The hook runtime and `match --format full` must produce the
  # *same* concatenation, so the logic lives here once: `Convention (path):`
  # headers, an over-cap summarized fallback, and the 10k character budget.
  module Rendering
    extend self

    # Total injected text stays under this; over it, fall back to headers + first
    # paragraph + a read-the-file instruction rather than spilling.
    CHAR_CAP = 10_000

    # Between rule blocks. A visible rule so concatenated conventions stay
    # readable to both a human and an agent.
    SEPARATOR = "\n\n---\n\n"

    # Render `{path, body}` pairs (bodies already frontmatter-stripped) into one
    # string. Empty input yields an empty string so callers can treat "nothing to
    # inject" uniformly.
    def context(docs : Array({String, String})) : String
      return "" if docs.empty?

      full = docs.map { |(path, body)| "Convention (#{path}):\n\n#{body}" }.join(SEPARATOR)
      full.size <= CHAR_CAP ? full : summarized(docs)
    end

    private def summarized(docs : Array({String, String})) : String
      header = "Several conventions matched but were summarized to fit the context budget; " \
               "read the cited files for the full text.\n\n"
      blocks = docs.map do |(path, body)|
        "Convention (#{path}): #{first_paragraph(body)}\n(Read the full rule in #{path}.)"
      end
      header + blocks.join(SEPARATOR)
    end

    private def first_paragraph(body : String) : String
      body.split("\n\n", 2).first.strip
    end
  end
end
