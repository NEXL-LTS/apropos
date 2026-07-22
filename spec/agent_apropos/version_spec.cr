require "../spec_helper"

describe AgentApropos::VERSION do
  it "is a semantic version string" do
    AgentApropos::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
  end
end
