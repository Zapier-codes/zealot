# frozen_string_literal: true

# TEMPORARY — Task 27b-iv, one-time bootstrap for the free-tier Render
# service. Render's free plan supports none of Shell, one-off Jobs, or the
# Pre-Deploy Command (all three are paid-only — confirmed against Render's
# own docs/API this session), so there is no way to run
# `rake catalog_index:generate_key` / `catalog_index:publish` against the
# deployed instance except through the app itself.
#
# This route also runs `db:migrate` first: this container's own
# docker/rootfs/etc/services.d/{zealot,job}/run scripts exec Puma / GoodJob
# directly with no migration step anywhere in the boot path, confirmed by
# reading them this session — so the pending catalog_index_signing_keys
# migration has never actually run against production. Every step here
# mirrors an existing rake task 1:1 (db:migrate, and
# lib/tasks/catalog_index.rake's generate_key/publish) — no new logic, just
# the same calls reachable over HTTP once, since Shell/Jobs/Pre-Deploy
# Command are all unavailable on this service's free plan (confirmed
# against Render's own docs and this service's own API response this
# session). It is authenticated the same way
# HyperswitchWebhooksController is: a shared secret, HMAC'd, compared with
# ActiveSupport::SecurityUtils.secure_compare (never `==`, which leaks
# timing). The secret lives only in OPS_SETUP_TOKEN, set on Render and
# never committed.
#
# ⚠️ DELETE THIS FILE, its route, and OPS_SETUP_TOKEN once the key has been
# generated and the first publish has succeeded. It is a standing risk to
# leave an authenticated-but-unscoped "run infra setup" endpoint live
# permanently, even behind a secret — remove it in the very next commit
# after use, not "later."
class OpsSetupController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def catalog_index_bootstrap
    return head :not_found unless token_valid?

    lines = []

    Rails.application.load_tasks unless Rake::Task.task_defined?('db:migrate')
    pending = ActiveRecord::Base.connection.migration_context.needs_migration?
    if pending
      Rake::Task['db:migrate'].invoke
      lines << 'migrate: ran'
    else
      lines << 'migrate: already up to date, skipped'
    end

    if CatalogIndexSigningKey.exists?
      lines << 'key: already exists, skipped generate_key'
    else
      key = CatalogIndexSigningKey.generate!
      lines << "key: generated  key_id=#{key.key_id}"
      lines << "key: public_key=#{key.public_key}   <-- copy this, hand it to D-store, then delete this route"
    end

    unless CatalogIndex::GithubPagesCommit.configured?
      lines << 'publish: SKIPPED — CATALOG_PAGES_REPO / CATALOG_PAGES_TOKEN not set on this service'
      return render plain: lines.join("\n")
    end

    result = CatalogIndex::Publish.call
    lines << "publish: #{result.status} generated_at=#{result.generated_at&.iso8601} " \
             "key_id=#{result.key_id} commit=#{result.commit_sha} hook=#{result.hook}"

    render plain: lines.join("\n")
  rescue StandardError => e
    Rails.logger.error("[OpsSetupController] #{e.class}: #{e.message}")
    render plain: "error: #{e.class}: #{e.message}", status: :internal_server_error
  end

  private

  def token_valid?
    secret = ENV['OPS_SETUP_TOKEN'].to_s.strip
    return false if secret.blank? # refuse by default — no accidental open route

    provided = request.headers['X-Ops-Setup-Token'].to_s
    return false if provided.blank?

    ActiveSupport::SecurityUtils.secure_compare(provided, secret)
  end
end
