# frozen_string_literal: true

source 'https://rubygems.org'

# Tooling only. ofdl itself has no gem dependencies -- see ofdl.gemspec, which
# declares none -- and nothing here is loaded at runtime.
#
# rubocop is pinned because .rubocop.yml sets NewCops: enable, so a newer
# rubocop switches on cops that were not in the config when it was written and
# a clean checkout starts reporting offences nobody introduced.
group :development do
  gem 'rubocop', '~> 1.89'

  # Both ship with Ruby, so `rake test` works without bundler. They are named
  # anyway because a Gemfile makes `bundle exec` a reasonable habit, and under
  # it an undeclared gem is not on the load path -- `bundle exec rake test`
  # fails with "rake is not currently included in the bundle" otherwise.
  gem 'minitest', '~> 6.0'
  gem 'rake', '~> 13.0'
end
