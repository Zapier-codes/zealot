# frozen_string_literal: true

# Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rule 6): the Play panel is optional per
# deployment and off by default for tenants. `ENABLE_PLAY_CATALOG=true` turns it on; the two backend
# commands are the separate processes that actually speak to Play (the licence boundary of §1.1 rule 7 —
# Zealot is MIT and never links the GPL Kotlin client into Rails). A backend with no command configured is
# simply not a candidate, so a deployment can run one, both, or neither.
Rails.application.configure do
  config.x.play_catalog = ActiveSupport::OrderedOptions.new
  config.x.play_catalog.enabled = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch('ENABLE_PLAY_CATALOG', 'false')
  )
  config.x.play_catalog.gplayapi_command = ENV['PLAY_GPLAYAPI_COMMAND'].to_s.strip.presence
  config.x.play_catalog.playstoreapi_command = ENV['PLAY_PLAYSTOREAPI_COMMAND'].to_s.strip.presence
  # A stable public app the daily canary reads (UNOFFICIAL-ROUTES §1.1 rule 3). Chosen by the operator.
  config.x.play_catalog.canary_package = ENV.fetch('PLAY_CANARY_PACKAGE', 'com.google.android.youtube')
end
