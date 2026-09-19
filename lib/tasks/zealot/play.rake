# frozen_string_literal: true

# Task 18: operator tool replacing the hand-run "play-check".
#
#   rake "zealot:play:check[com.example.app]"   probe one applicationId
#                                               (prints the result, exits 1 unless ready)
#   rake zealot:play:check                      run the full check for every app that has a
#                                               Play package name: records the result on the app
#                                               and resumes any release waiting on Play setup
#
# A returned edit id means the Google side is finished: the app exists, its
# first bundle has been uploaded and the service account has access.
namespace :zealot do
  namespace :play do
    desc 'Zealot | Check Play Console setup for a package (or every app with a Play package name)'
    task :check, [:package_name] => :environment do |_task, args|
      if args[:package_name].present?
        result = Anthropic::PlayPreflightService.new.check(args[:package_name])
        puts "Package:  #{args[:package_name]}"
        puts "Result:   #{result.code}"
        puts "Edit id:  #{result.edit_id}" if result.edit_id.present?
        puts result.message
        exit(1) unless result.ready?
      else
        apps = App.where.not(play_package_name: nil).order(:id)
        puts 'No app has a Play package name yet.' if apps.empty?

        apps.each do |app|
          AnthropicPlayPreflightJob.perform_now(app.id)
          app.reload
          puts "#{app.name} (#{app.play_package_name}): #{app.play_setup_status}"
          puts "  #{app.play_setup_message}" unless app.play_setup_ready?
        end
      end
    end
  end
end
