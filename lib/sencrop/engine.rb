module Sencrop
  class Engine < ::Rails::Engine

    initializer 'sencrop.assets.precompile' do |app|
      app.config.assets.precompile += %w[*.svg *.png]
    end

    initializer :i18n do |app|
      app.config.i18n.load_path += Dir[Sencrop::Engine.root.join('config', 'locales', '**', '*.yml')]
    end

    initializer :ekylibre_sencrop_integration do
      Sencrop::SencropIntegration.on_check_success do
        SencropFirstRunJob.perform_later
      end

      Sencrop::SencropIntegration.run every: :hour do
        last_sencrop_import = Preference.find_by(name: 'last_sencrop_import')
        sencrop_import_running = Preference.find_by(name: 'sencrop_import_running')
        if last_sencrop_import&.value && !sencrop_import_running&.value
          last_imported_at = last_sencrop_import.value
          SencropFetchUpdateCreateJob.perform_now(last_imported_at)
        end
      end
    end

  end
end
