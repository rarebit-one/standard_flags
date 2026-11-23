source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", require: false
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-rspec", require: false
end

group :test do
  gem "actionpack", ">= 8.1", require: false
  gem "activejob", ">= 8.1", require: false
  # Runtime rules. Never gemspec dependencies: ActiveRecord loads only when a
  # host turns runtime rules on, and only the :db specs (DATABASE_URL set)
  # touch Postgres.
  gem "activerecord", ">= 8.1", require: false
  gem "pg", ">= 1.5", require: false
  gem "strong_migrations", require: false
  gem "rack-test", require: false
  gem "sentry-ruby", ">= 5.17", require: false
  gem "standard_health", ">= 0.8", require: false
  # The optional OpenFeature provider (require "standard_flags/open_feature").
  # Never a gemspec dependency: only hosts that use OpenFeature bring it.
  gem "openfeature-sdk", "~> 0.8", require: false
end
