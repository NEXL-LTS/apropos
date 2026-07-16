require "../spec_helper"

describe Muninn::VERSION do
  it "is a semantic version string" do
    Muninn::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
  end
end
