require 'rest-client'
require 'base64'

module Sencrop
  class ServiceError < StandardError; end

  class SencropIntegration < ActionIntegration::Base
    BASE_URL  = 'https://api.sencrop.com/v1'.freeze
    TOKEN_URL = "#{BASE_URL}/oauth2/token".freeze
    PING_URL  = "#{BASE_URL}/ping".freeze
    ME_URL    = "#{BASE_URL}/me".freeze

    TOKEN_REFRESH_MARGIN = 60 # seconds before expiry to trigger a refresh

    DEFAULT_MEASURES = %w[
      RAIN_FALL TEMPERATURE TEMPERATURE_MIN TEMPERATURE_MAX
      RELATIVE_HUMIDITY WIND_SPEED WIND_GUST
    ].join(',').freeze

    authenticate_with :check do
      parameter :application_id
      parameter :application_secret
    end

    calls :retrieve_token, :fetch_me, :fetch_devices, :fetch_device,
          :fetch_hourly_data, :fetch_daily_data, :fetch_statistics

    # POST /v1/oauth2/token with Basic auth
    # body: { grant_type: 'client_credentials', scope: 'user' }
    # response: { access_token, token_type, expires_in, scope }
    def retrieve_token
      integration = fetch
      app_id     = integration.parameters['application_id']
      app_secret = integration.parameters['application_secret']
      basic      = Base64.strict_encode64("#{app_id}:#{app_secret}")
      payload    = { grant_type: 'client_credentials', scope: 'user' }

      post_json(TOKEN_URL, payload,
                'Authorization' => "Basic #{basic}",
                'Content-Type'  => 'application/json') do |r|
        r.success do
          body = JSON(r.body).deep_symbolize_keys
          r.error :api_down unless body[:access_token]
        end

        r.error do
          Rails.logger.error '[Sencrop] OAuth2 token retrieval failed'.red
        end
      end
    end

    # GET /v1/ping (auth required)
    def check(integration = nil)
      integration = fetch integration
      token_response = retrieve_token
      token = JSON(token_response.body).deep_symbolize_keys[:access_token]

      get_json(PING_URL, 'Authorization' => "Bearer #{token}") do |r|
        r.success do
          Rails.logger.info '[Sencrop] API reachable'.green
        end

        r.error do
          r.error :api_down
        end
      end
    end

    # GET /v1/me
    # response: { item: userId, users: {...}, places: {...} }
    def fetch_me
      get_json(ME_URL, 'Authorization' => "Bearer #{cached_token}") do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error '[Sencrop] /me failed'.red
        end
      end
    end

    # GET /v1/users/{userId}/devices
    # response: { items: [ids], devicesStatuses: { id => { contents: { name, latitude, longitude } } } }
    def fetch_devices(user_id)
      url = "#{BASE_URL}/users/#{user_id}/devices?includeHistory=false"
      get_json(url, 'Authorization' => "Bearer #{cached_token}") do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Sencrop] /devices failed for user #{user_id}".red
        end
      end
    end

    # GET /v1/users/{userId}/devices/{deviceId}
    def fetch_device(user_id, device_id)
      url = "#{BASE_URL}/users/#{user_id}/devices/#{device_id}"
      get_json(url, 'Authorization' => "Bearer #{cached_token}") do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Sencrop] device #{device_id} fetch failed".red
        end
      end
    end

    # GET /v1/users/{userId}/devices/{deviceId}/data/hourly
    # before_date: ISO 8601 string (e.g. '2022-01-28T01:00:00.000Z')
    # days: integer
    # measures: comma-separated list of measure codes
    # response: { item, measures: { interval: '1h', data: [{ key, MEASURE: { value } }] } }
    def fetch_hourly_data(user_id, device_id, before_date, days, measures = DEFAULT_MEASURES)
      url = "#{BASE_URL}/users/#{user_id}/devices/#{device_id}/data/hourly" \
            "?beforeDate=#{before_date}&days=#{days}&measures=#{measures}"
      get_json(url, 'Authorization' => "Bearer #{cached_token}") do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Sencrop] hourly data fetch failed for device #{device_id}".red
        end
      end
    end

    def fetch_daily_data(user_id, device_id, before_date, days, measures = DEFAULT_MEASURES)
      url = "#{BASE_URL}/users/#{user_id}/devices/#{device_id}/data/daily" \
            "?beforeDate=#{before_date}&days=#{days}&measures=#{measures}"
      get_json(url, 'Authorization' => "Bearer #{cached_token}") do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Sencrop] daily data fetch failed for device #{device_id}".red
        end
      end
    end

    def fetch_statistics(user_id, device_id, start_date, end_date, measures = DEFAULT_MEASURES, patched: false)
      url = "#{BASE_URL}/users/#{user_id}/devices/#{device_id}/statistics" \
            "?startDate=#{start_date}&endDate=#{end_date}&measures=#{measures}&patched=#{patched}"
      get_json(url, 'Authorization' => "Bearer #{cached_token}") do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Sencrop] statistics fetch failed for device #{device_id}".red
        end
      end
    end

    private

    # Returns a valid access token, refreshing it if needed.
    # The token is cached across calls within the same job to avoid hammering /oauth2/token.
    def cached_token
      expires_at = Preference.find_by(name: 'sencrop_token_expires_at')&.value.to_i
      if expires_at <= Time.zone.now.to_i + TOKEN_REFRESH_MARGIN
        refresh_token!
      end
      Preference.find_by(name: 'sencrop_access_token').value
    end

    def refresh_token!
      response = retrieve_token
      body = JSON(response.body).deep_symbolize_keys
      Preference.set!('sencrop_access_token', body[:access_token], 'string')
      Preference.set!('sencrop_token_expires_at',
                      Time.zone.now.to_i + body[:expires_in].to_i,
                      'integer')
    end
  end
end
