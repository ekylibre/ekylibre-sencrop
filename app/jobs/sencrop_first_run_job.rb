class SencropFirstRunJob < ActiveJob::Base
  queue_as :default

  TRANSCODE_INDICATORS = {
    'RAIN_FALL'         => { indicator: :cumulated_rainfall,        unit: :millimeter },
    'TEMPERATURE'       => { indicator: :average_temperature,       unit: :celsius },
    'TEMPERATURE_MIN'   => { indicator: :minimal_temperature,       unit: :celsius },
    'TEMPERATURE_MAX'   => { indicator: :maximal_temperature,       unit: :celsius },
    'RELATIVE_HUMIDITY' => { indicator: :average_relative_humidity, unit: :percent },
    'WIND_SPEED'        => { indicator: :average_wind_speed,        unit: :kilometer_per_hour },
    'WIND_GUST'         => { indicator: :maximal_wind_speed,        unit: :kilometer_per_hour }
  }.freeze

  WINDOW_DAYS  = 15
  WINDOW_COUNT = 10 # 150 days total

  # Get ~150 days of historical weather data, in 10 windows of 15 days.
  def perform
    Preference.set!('sencrop_import_running', true, 'boolean')

    last_sampled_at_list = []

    user_id = resolve_user_id
    return unless user_id

    Sencrop::SencropIntegration.fetch_devices(user_id).execute do |c|
      c.success do |response|
        items            = response[:items] || []
        devices_statuses = response[:devicesStatuses] || {}

        items.each do |device_id|
          device  = devices_statuses[device_id.to_s.to_sym] || devices_statuses[device_id.to_s]
          next unless device

          contents = device[:contents] || {}
          lat = contents[:latitude]
          lon = contents[:longitude]
          next unless lat && lon

          geolocation = ::Charta.new_point(lat, lon).to_ewkt

          sensor = Sensor.find_or_create_by(
            vendor_euid:    :sencrop,
            euid:           device_id,
            retrieval_mode: :integration
          )
          sensor.update!(
            name:                  contents[:name].to_s,
            model_euid:            :sencrop,
            partner_url:           'https://app.sencrop.com',
            last_transmission_at:  Time.zone.now
          )

          (0...WINDOW_COUNT).to_a.reverse.each do |i|
            before_date_iso = (Time.zone.now.utc - (i * WINDOW_DAYS).days).iso8601

            Sencrop::SencropIntegration.fetch_hourly_data(user_id, device_id, before_date_iso, WINDOW_DAYS).execute do |hc|
              hc.success do |hourly_response|
                data_points = hourly_response.dig(:measures, :data) || []

                data_points.each do |point|
                  key_ms  = point[:key]
                  next unless key_ms

                  read_at          = Time.at(key_ms / 1000.0).utc
                  reference_number = "#{sensor.euid}_#{key_ms}"

                  analyse = sensor.analyses.find_or_initialize_by(
                    reference_number:       reference_number,
                    sampled_at:             read_at,
                    analysed_at:            read_at,
                    retrieval_status:       :ok,
                    nature:                 :sensor_analysis,
                    sampling_temporal_mode: :period
                  )
                  if analyse.new_record?
                    analyse.geolocation = geolocation
                    analyse.save!
                  end

                  unless analyse.items.any?
                    TRANSCODE_INDICATORS.each do |code, mapping|
                      measure = point[code.to_sym] || point[code]
                      value   = measure.is_a?(Hash) ? (measure[:value] || measure['value']) : nil
                      next if value.nil?

                      analyse.read!(mapping[:indicator], value.in(mapping[:unit]))
                    end
                  end
                end

                if i.zero? && data_points.any?
                  max_key_ms = data_points.map { |p| p[:key].to_i }.max
                  last_sampled_at_list << (max_key_ms / 1000)
                end
              end
            end
          end
        end
      end
    end

    Preference.set!('last_sencrop_import', last_sampled_at_list.min || Time.zone.now.to_i, 'integer')
    Preference.set!('sencrop_import_running', false, 'boolean')
  end

  private

  def resolve_user_id
    response = Sencrop::SencropIntegration.fetch_me
    body = JSON(response.body).deep_symbolize_keys
    body[:item]
  rescue StandardError => e
    Rails.logger.error "[Sencrop] Unable to resolve user_id: #{e.message}"
    Preference.set!('sencrop_import_running', false, 'boolean')
    nil
  end
end
