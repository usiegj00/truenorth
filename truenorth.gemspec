# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'truenorth'
  spec.version       = '0.3.0'
  spec.authors       = ['usiegj00']
  spec.email         = ['112138+usiegj00@users.noreply.github.com']

  spec.summary       = 'CLI client for NorthStar facility booking systems'
  spec.description   = 'A command-line interface for checking availability, managing bookings, ' \
                       'and interacting with NorthStar-powered facility reservation systems.'
  spec.homepage      = 'https://github.com/usiegj00/truenorth'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = 'bin'
  spec.executables = ['truenorth']
  spec.require_paths = ['lib']

  spec.add_dependency 'base64', '~> 0.2'
  spec.add_dependency 'nokogiri', '~> 1.15'
  spec.add_dependency 'thor', '~> 1.3'
  spec.add_dependency 'tty-table', '~> 0.12'

  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
