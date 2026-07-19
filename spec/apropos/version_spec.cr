require "../spec_helper"

describe Apropos::VERSION do
  it "is a semantic version string" do
    Apropos::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
  end
end
