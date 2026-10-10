# frozen_string_literal: true

# Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1): operator entry points for the Play import
# bridge. Nothing here is used by the app's request path; these are the console commands the operator runs
# to prove a backend and to read one labelled panel.
#
#   rake play_catalog:canary PACKAGE=com.example.app   # run the canary now (records ok/degraded), and
#                                                       # print each backend's state
#   rake play_catalog:status                           # show the recorded state of every backend
#   rake play_catalog:show PACKAGE=com.example.app      # read one panel through the adapter (respects the
#                                                       # enable switch, the cache and the failover order)
namespace :play_catalog do
  # A small helper shared by the tasks below (defined here, not as a bare `def`, so it is a local proc the
  # task blocks close over rather than a method on Rake's DSL).
  print_states = lambda do
    states = PlaySourceState.order(:backend)
    if states.empty?
      puts 'No canary has run yet; every backend is unproven (the adapter will not use it).'
    else
      states.each do |s|
        puts format('%-14s %-9s checked=%s ok=%s%s',
                    s.backend, s.status,
                    s.last_checked_at&.iso8601 || '-', s.last_ok_at&.iso8601 || '-',
                    s.error.present? ? " error=#{s.error}" : '')
      end
    end
  end

  desc 'Run the Play backend canary now (Z-P25) and print each backend state'
  task canary: :environment do
    package = ENV['PACKAGE'].presence || Rails.configuration.x.play_catalog.canary_package
    outcomes = Play::Canary.run(package: package)
    if outcomes.empty?
      abort 'No backend command configured (set PLAY_GPLAYAPI_COMMAND / PLAY_PLAYSTOREAPI_COMMAND).'
    end

    outcomes.each do |o|
      puts "#{o.backend}: #{o.ok ? 'ok' : "degraded (#{o.error})"}"
    end
    puts
    print_states.call
  end

  desc 'Show the recorded state of every Play backend (Z-P25)'
  task status: :environment do
    puts "ENABLE_PLAY_CATALOG=#{Rails.configuration.x.play_catalog.enabled}"
    print_states.call
  end

  desc 'Read one labelled Play panel through the adapter (Z-P25). PACKAGE=<name>'
  task show: :environment do
    package = ENV['PACKAGE'].to_s.strip
    abort 'Set PACKAGE=<play package name>.' if package.empty?

    result = Play::CatalogAdapter.call(package)
    puts "status:  #{result.status}"
    puts "backend: #{result.backend}" if result.backend
    puts "error:   #{result.error}" if result.error.present?
    puts JSON.pretty_generate(result.panel) if result.panel
  end
end
