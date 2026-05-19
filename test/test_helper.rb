# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'vcr'
require 'json'
require 'base64'

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path('cassettes', __dir__)
  c.hook_into :webmock
  c.default_cassette_options = { record: :new_episodes }
  c.filter_sensitive_data('<APP_ID>')     { ENV.fetch('SENCROP_APP_ID', 'app-id') }
  c.filter_sensitive_data('<APP_SECRET>') { ENV.fetch('SENCROP_APP_SECRET', 'app-secret') }
  c.filter_sensitive_data('<BASIC_AUTH>') do
    Base64.strict_encode64("#{ENV.fetch('SENCROP_APP_ID', 'app-id')}:#{ENV.fetch('SENCROP_APP_SECRET', 'app-secret')}")
  end
end
