require_relative "lib/roundhouse_ui/version"

Gem::Specification.new do |spec|
  spec.name        = "roundhouse_ui"
  spec.version     = RoundhouseUi::VERSION
  spec.authors     = [ "R.J. Robinson" ]
  spec.email       = [ "robertj.robinson@gmail.com" ]
  spec.homepage    = "https://github.com/rjrobinson/roundhouse_ui"
  spec.summary     = "Roundhouse — a real-time ops UI for Sidekiq and Solid Queue."
  spec.description = "Mountable Rails engine for Sidekiq or Solid Queue: grouped errors, argument " \
                     "search, filter-scoped bulk actions, enforced pause, snapshots, audit " \
                     "log. Mounts alongside or instead of Sidekiq::Web. Not affiliated with " \
                     "or endorsed by Contributed Systems LLC; Sidekiq, Sidekiq Pro and Sidekiq " \
                     "Enterprise are their trademarks."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "sidekiq", ">= 6.5"
end
