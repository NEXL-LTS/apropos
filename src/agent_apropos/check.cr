module AgentApropos
  # One environment check reported by `agent-apropos doctor`: `:ok`, `:warn`
  # (advisory), or `:fail` (exit 1). Lives outside `Doctor` (rather than as
  # `Doctor::Check`) so `Agents::Agent#checks` can return it without every
  # agent file requiring `doctor.cr` — `Doctor` still resolves the bare
  # `Check` name via Crystal's lexical constant lookup.
  record Check, status : Symbol, name : String, detail : String
end
