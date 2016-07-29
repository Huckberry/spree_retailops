# encoding: UTF-8
Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree_retailops'
  s.version     = '2.3.0'
  s.summary     = 'Spree extension to allow PIM and OMS integration from RetailOps'
  s.description = 'Spree extension to allow PIM and OMS integration from RetailOps'
  s.required_ruby_version = '>= 1.9.3'

  s.license   = 'MIT'

  s.author    = 'Stefan O\'Rear'
  s.email     = 'sorear@gudtech.com'
  # s.homepage  = 'http://www.spreecommerce.com'

  s.files       = `git ls-files`.split("\n")
  s.test_files  = Dir["spec/**/*"]
  s.require_path = 'lib'
  s.requirements << 'none'

  s.add_dependency 'spree_core', '>= 2.4.6', '< 3'
  s.add_dependency 'spree_api', '>= 2.4.6', '< 3'

  s.add_development_dependency 'rspec-rails',  '~> 3.0'
  s.add_development_dependency 'factory_girl_rails', '~> 4.4'
  s.add_development_dependency 'database_cleaner'
  s.add_development_dependency 'byebug'

  s.add_development_dependency 'coffee-rails'
  s.add_development_dependency 'ffaker'
  s.add_development_dependency 'sass-rails'
  s.add_development_dependency 'sqlite3'
end
