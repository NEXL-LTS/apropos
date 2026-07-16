require "./version"

module Muninn
  # Command routing for the `muninn` binary.
  #
  # At M0 only `--version` and `--help` are wired; every subcommand named in the
  # usage text lands in a later milestone (PRD §9). All output goes through
  # injected IO so the router is unit-testable without a subprocess.
  class CLI
    USAGE = <<-USAGE
      muninn — deliver the right conventions to the right moment.

      Usage: muninn <command> [options]

      Commands (see PRD §5; most land after M0):
        init        Bootstrap the convention structure into a repo
        generate    Compile frontmatter into the index + skill wrappers
        hook pre    PreToolUse handler  (Layer 2, path-scoped)
        hook post   PostToolUse handler (Layer 3, construct-scoped)
        match       Resolve conventions for given paths
        review      Resolve conventions for a git range
        lint        Validate the convention structure
        doctor      Check the environment
        help        Explain the mental model

      Options:
        --version   Print version and exit
        --help, -h  Print this usage and exit
      USAGE

    def self.run(args : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR) : Int32
      new(stdout, stderr).run(args)
    end

    def initialize(@stdout : IO, @stderr : IO)
    end

    def run(args : Array(String)) : Int32
      case args.first?
      when nil, "--help", "-h", "help"
        @stdout.puts USAGE
        0
      when "--version", "version"
        @stdout.puts "muninn #{VERSION}"
        0
      else
        @stderr.puts "muninn: unknown command '#{args.first}'. Run `muninn --help`."
        1
      end
    end
  end
end
