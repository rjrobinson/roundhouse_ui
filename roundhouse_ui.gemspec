require_relative "lib/roundhouse_ui/version"

Gem::Specification.new do |spec|
  spec.name        = "roundhouse_ui"
  spec.version     = RoundhouseUi::VERSION
  spec.authors     = [ "R.J. Robinson" ]
  spec.email       = [ "rj@trainual.com" ]
  spec.homepage    = "https://github.com/roundhouse/roundhouse_ui"
  spec.summary     = "Roundhouse — a modern, real-time web UI for Sidekiq."
  spec.description = "A mountable Rails engine that replaces the Sidekiq Web UI with a real-time " \
                     "control plane: live queues, search, bulk actions, stuck-queue detection, " \
                     "snapshots, and pluggable observability."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "sidekiq", ">= 7.0"
end
