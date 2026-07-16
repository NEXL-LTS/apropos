require "./version"
require "./generate"
require "./hook"
require "./repo_root"
require "./filesystem"

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

    def self.run(args : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR, stdin : IO = STDIN) : Int32
      new(stdout, stderr, stdin).run(args)
    end

    def initialize(@stdout : IO, @stderr : IO, @stdin : IO = STDIN)
    end

    def run(args : Array(String)) : Int32
      case args.first?
      when nil, "--help", "-h", "help"
        @stdout.puts USAGE
        0
      when "--version", "version"
        @stdout.puts "muninn #{VERSION}"
        0
      when "generate"
        handle_generate(args[1..])
      when "hook"
        handle_hook(args[1..])
      else
        @stderr.puts "muninn: unknown command '#{args.first}'. Run `muninn --help`."
        1
      end
    end

    # `muninn generate [--check] [--repo-root DIR]` (PRD §5.3). Argument parsing
    # stays hand-rolled and small; the work lives in `Generate` behind an
    # injected `Filesystem` so it is unit-testable without a subprocess.
    private def handle_generate(args : Array(String)) : Int32
      check = false
      override : String? = nil

      index = 0
      while index < args.size
        case arg = args[index]
        when "--check"
          check = true
        when "--repo-root"
          index += 1
          value = args[index]?
          return usage_error("--repo-root requires a directory") if value.nil?
          override = value
        else
          return usage_error("unknown option '#{arg}'")
        end
        index += 1
      end

      root = override ? Path[override] : Muninn.find_repo_root(Path[Dir.current])
      if root.nil?
        @stderr.puts "muninn generate: no repository root found (looked for .git). Pass --repo-root."
        return 1
      end

      fs = Filesystem::Real.new
      if check
        Generate.check(root, fs, @stdout, @stderr)
      else
        Generate.run(root, fs, @stdout, @stderr)
      end
    end

    private def usage_error(message : String) : Int32
      @stderr.puts "muninn generate: #{message}"
      1
    end

    # `muninn hook pre|post [--repo-root DIR]` (PRD §5.4, §5.5). Claude Code
    # invokes these with the payload on stdin. The whole family fails *open*: an
    # unknown subcommand or a bad `--repo-root` yields exit 0 with no output
    # rather than ever blocking an edit. All work lives in `Hook`.
    private def handle_hook(args : Array(String)) : Int32
      event = args.first?
      return 0 unless event == "pre" || event == "post"

      override = repo_root_override(args[1..])
      verbose = {"1", "true"}.includes?(ENV["MUNINN_VERBOSE"]?)
      fs = Filesystem::Real.new
      now = Time.utc
      if event == "pre"
        Hook.pre(@stdin, @stdout, fs, now, override, verbose)
      else
        Hook.post(@stdin, @stdout, fs, now, override, verbose)
      end
    end

    # Extract a `--repo-root DIR` override from hook args, ignoring anything else
    # (fail open — a stray flag must not break the hook path).
    private def repo_root_override(args : Array(String)) : String?
      index = args.index("--repo-root")
      index ? args[index + 1]? : nil
    end
  end
end
