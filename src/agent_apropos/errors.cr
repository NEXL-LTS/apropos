module AgentApropos
  # Base class for agent-apropos-specific errors. Callers (generate, lint, review)
  # fail closed by letting these propagate; hook subcommands fail open by
  # rescuing them and exiting 0. One base type makes both easy.
  class Error < Exception
  end
end
