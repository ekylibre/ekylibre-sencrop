# frozen_string_literal: true

require_relative '../test_helper'

# Stand-alone tests for the OAuth2/HTTP contract with the Sencrop API.
# These tests don't load the Ekylibre Rails environment; they verify that
# the URLs and payloads built by the integration match the documented API.
class SencropIntegrationContractTest < Minitest::Test
  BASE_URL = 'https://api.sencrop.com/v1'

  def setup
    @app_id     = 'test-app-id'
    @app_secret = 'test-app-secret'
    @basic      = Base64.strict_encode64("#{@app_id}:#{@app_secret}")
    @token      = 'test-access-token'
    @user_id    = 1664
    @device_id  = 33
  end

  def test_oauth2_token_endpoint_shape
    stub_request(:post, "#{BASE_URL}/oauth2/token")
      .with(
        headers: {
          'Authorization' => "Basic #{@basic}",
          'Content-Type'  => 'application/json'
        },
        body: { grant_type: 'client_credentials', scope: 'user' }.to_json
      )
      .to_return(
        status:  200,
        body:    { access_token: @token, token_type: 'Bearer', expires_in: 3600, scope: 'user' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = post_oauth_token
    assert_equal 200, response.code.to_i
    body = JSON.parse(response.body)
    assert_equal @token, body['access_token']
    assert_equal 3600, body['expires_in']
  end

  def test_me_endpoint_returns_user_id
    stub_request(:get, "#{BASE_URL}/me")
      .with(headers: { 'Authorization' => "Bearer #{@token}" })
      .to_return(
        status:  200,
        body:    { item: @user_id, users: { @user_id.to_s => { organisationsIds: [] } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = bearer_get("#{BASE_URL}/me")
    body = JSON.parse(response.body)
    assert_equal @user_id, body['item']
  end

  def test_devices_endpoint_returns_location
    stub_request(:get, "#{BASE_URL}/users/#{@user_id}/devices?includeHistory=false")
      .with(headers: { 'Authorization' => "Bearer #{@token}" })
      .to_return(
        status: 200,
        body:   {
          items: [@device_id],
          devicesStatuses: {
            @device_id.to_s => {
              id: @device_id.to_s,
              identification: 'SC999999',
              contents: { name: 'Test station', latitude: 47.218, longitude: -1.553 }
            }
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = bearer_get("#{BASE_URL}/users/#{@user_id}/devices?includeHistory=false")
    body = JSON.parse(response.body)
    assert_equal [@device_id], body['items']
    device = body['devicesStatuses'][@device_id.to_s]
    assert_equal 47.218, device['contents']['latitude']
    assert_equal(-1.553, device['contents']['longitude'])
  end

  def test_hourly_endpoint_returns_buckets
    before_date = '2022-01-28T01:00:00.000Z'
    measures    = 'RAIN_FALL,TEMPERATURE'
    url         = "#{BASE_URL}/users/#{@user_id}/devices/#{@device_id}/data/hourly" \
                  "?beforeDate=#{before_date}&days=7&measures=#{measures}"

    stub_request(:get, url)
      .with(headers: { 'Authorization' => "Bearer #{@token}" })
      .to_return(
        status: 200,
        body:   {
          item: @device_id,
          measures: {
            interval: '1h',
            data: [
              { key: 1_507_186_800_000, RAIN_FALL: { value: 0.4 }, TEMPERATURE: { value: 18.2 } }
            ]
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = bearer_get(url)
    body = JSON.parse(response.body)
    point = body['measures']['data'].first
    assert_equal 1_507_186_800_000, point['key']
    assert_equal 0.4, point['RAIN_FALL']['value']
    assert_equal 18.2, point['TEMPERATURE']['value']
  end

  def test_ping_endpoint
    stub_request(:get, "#{BASE_URL}/ping")
      .with(headers: { 'Authorization' => "Bearer #{@token}" })
      .to_return(status: 200, body: 'pong')

    response = bearer_get("#{BASE_URL}/ping")
    assert_equal 200, response.code.to_i
  end

  private

  def post_oauth_token
    uri = URI("#{BASE_URL}/oauth2/token")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.path)
    request['Authorization'] = "Basic #{@basic}"
    request['Content-Type']  = 'application/json'
    request.body = { grant_type: 'client_credentials', scope: 'user' }.to_json
    http.request(request)
  end

  def bearer_get(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    request = Net::HTTP::Get.new(path)
    request['Authorization'] = "Bearer #{@token}"
    http.request(request)
  end
end
