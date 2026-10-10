# frozen_string_literal: true

# Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rule 3): run the daily canary. Off unless
# ENABLE_PLAY_CATALOG is true and at least one backend command is configured; otherwise it logs and does
# nothing, so an unconfigured deploy is never broken by it (the same posture as CatalogIndexPublishJob).
#
#   rails runner 'PlayCatalogCanaryJob.perform_now'
class PlayCatalogCanaryJob < ApplicationJob
  queue_as :default

  def perform
    unless Rails.configuration.x.play_catalog.enabled
      Rails.logger.info('[PlayCatalogCanaryJob] skipped: set ENABLE_PLAY_CATALOG=true')
      return
    end

    outcomes = Play::Canary.run
    if outcomes.empty?
      Rails.logger.warn('[PlayCatalogCanaryJob] no backend command configured ' \
                        '(PLAY_GPLAYAPI_COMMAND / PLAY_PLAYSTOREAPI_COMMAND)')
      return
    end

    outcomes.each do |o|
      Rails.logger.info("[PlayCatalogCanaryJob] #{o.backend} #{o.ok ? 'ok' : "degraded: #{o.error}"}")
    end
  end
end
