# frozen_string_literal: true

# Task 36b: console entry points for the Google registration work. Neither task is run by anything
# automatic. Read docs/android_developer_console_api.md before using them.
namespace :google_adc do
  desc 'READ-ONLY: list what Google has registered under the organisation account beside Zealot\'s apps'
  task inventory: :environment do
    abort 'CLIENT_ID, CLIENT_SECRET and ADC_REFRESH_TOKEN must all be set' unless GoogleAdc::Client.configured?

    puts GoogleAdc::Inventory.call.to_text
  end

  desc 'Register ONE package name (writes unless ADC_DRY_RUN=true): rake "google_adc:register[com.example.app]"'
  task :register, [:package_name] => :environment do |_task, args|
    abort 'give a package name: rake "google_adc:register[com.example.app]"' if args[:package_name].blank?

    app = App.find_by(play_package_name: args[:package_name])
    result = GoogleAdc::Registrar.call(package_name: args[:package_name], app: app, force: true)
    puts "outcome: #{result.outcome}"
    puts "planned: #{result.planned.join('; ')}" if result.planned.any?
    if result.registration
      puts "state: #{result.registration.state}"
      puts "last error: #{result.registration.last_error}" if result.registration.last_error.present?
    end
  end
end
