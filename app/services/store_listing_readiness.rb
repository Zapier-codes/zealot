# frozen_string_literal: true

# Task 42e: one read-only answer to "why is this app (not) in D-Store?". It reports the facts the catalog
# index depends on and lists, in plain words, whatever keeps the app out of it today. It changes nothing and
# never publishes. The checks mirror `CatalogIndex::Serializer`: only a `live` listing is indexed, only a
# release whose status is `available` counts, and an app that belongs to a tenant is in that tenant's index,
# not the default one D-Store reads (docs/ci/operator-runbook.md section 17).
#
# `eligible_for_catalog_index` is "no blocker found here", not a promise: the published file is what D-Store
# reads, so confirm it with the index itself after a publish.
class StoreListingReadiness
  def self.call(app)
    new(app).call
  end

  # A payment as the API shows it: no secrets and no raw provider response.
  def self.payment_json(payment)
    return nil unless payment

    { payment_id: payment.id, purpose: payment.purpose, status: payment.status, amount_cents: payment.amount_cents,
      currency: payment.currency, hyperswitch_payment_id: payment.hyperswitch_payment_id,
      paid_at: payment.paid_at, created_at: payment.created_at }
  end

  def initialize(app)
    @app = app
  end

  def call
    {
      app_id: @app.id,
      name: @app.name,
      owner: owner_json,
      tenant: @app.tenant&.tenant_id,
      archived: @app.archived ? true : false,
      listing_status: @app.listing_status,
      publisher_profile: @app.publisher_profile.present?,
      latest_payment: self.class.payment_json(@app.payments.where(purpose: 'listing_fee').order(:id).last),
      listing_fee: StoreListingPayment.price_json,
      maintenance: maintenance_json,
      featured: @app.featured ? true : false,
      editors_pick: @app.editors_pick ? true : false,
      latest_release: release_json(latest_release),
      available_release: release_json(available_release),
      blockers: blockers,
      eligible_for_catalog_index: blockers.empty?
    }
  end

  private

  def releases
    @releases ||= @app.play_releases_scope.order(:id).to_a
  end

  def latest_release
    releases.last
  end

  def available_release
    releases.reverse.find { |release| release.status == 'available' }
  end

  def maintenance_json
    billing = @app.maintenance_billing
    return nil unless billing

    { status: billing.status, amount_cents: billing.amount_cents, currency: billing.currency,
      billing_period: billing.billing_period, paid_through: billing.paid_through,
      next_charge_at: billing.next_charge_at, lapsed: billing.lapsed_at.present? }
  end

  def owner_json
    user = @app.owner&.user
    user && { user_id: user.id, email: user.email }
  end

  def release_json(release)
    return nil unless release

    {
      id: release.id, release_version: release.release_version, build_version: release.build_version,
      status: release.status, ci_compile_state: release.ci_compile_state, signed: release.signed ? true : false
    }
  end

  def blockers
    @blockers ||= [].tap do |list|
      list << 'the app is archived' if @app.archived
      list << "the app belongs to tenant #{@app.tenant.tenant_id}, so it is in that tenant's index, not the default one" if @app.tenant
      list << "listing_status is #{@app.listing_status}; only live apps are indexed" unless @app.listing_live?
      list << 'no release has status available (a held release is not shown)' unless available_release
    end
  end
end
