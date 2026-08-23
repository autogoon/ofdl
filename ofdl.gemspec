# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = 'ofdl'
  s.version     = '0.1.0'
  s.summary     = 'Onlyfans downloader'
  s.description = 'Downloads media from Onlyfans'
  s.authors     = ['autogoon']
  s.license     = 'MIT'

  s.files       = Dir['lib/**/*.rb', 'bin/*', '*.example.json']
  s.bindir      = 'bin'
  s.executables = %w[ofdl]

  s.required_ruby_version = '>= 4.0'
  s.metadata['rubygems_mfa_required'] = 'true'
end
