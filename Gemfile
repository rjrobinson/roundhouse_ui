source "https://rubygems.org"

# Specify your gem's dependencies in roundhouse_ui.gemspec.
gemspec

# CI tests against multiple Sidekiq versions (see .github/workflows/ci.yml).
# Unset locally, so the gemspec's ">= 6.5" resolves to the latest.
gem "sidekiq", ENV["SIDEKIQ_VERSION"] if ENV["SIDEKIQ_VERSION"]

gem "puma"

gem "propshaft"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
