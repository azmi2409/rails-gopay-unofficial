Gem::Specification.new do |spec|
  spec.name = "rails-gopay-unofficial"
  spec.version = "0.1.1"
  spec.authors = ["Azmi"]
  spec.summary = "Unofficial GoBiz QRIS client"
  spec.description = "Generate dynamic QRIS codes and access GoBiz merchant transactions."
  spec.homepage = "https://github.com/azmi2409/rails-gopay-unofficial"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
