# frozen_string_literal: true

# Z-P10 / Task 50: the one place that starts, progresses and cancels a payout on B-Pay-backend. The Console
# controller and any future bulk/scheduled job both call it, so the amount checks, the failure handling and
# the status mapping cannot drift between doors.
#
# It never guesses a status: every write is a B-Pay answer (create/confirm/cancel/fulfill/retrieve). A payout
# row is created `created` before the call and left `failed` with the reason if B-Pay refuses, so a refusal is
# visible rather than lost.
#
# Bulk and scheduled payouts are this class called in a loop — B-Pay-backend has no bulk endpoint (see
# docs/UNOFFICIAL-ROUTES.md section 8), so `bulk` is deliberately a thin loop, not a fake API.
class PayoutRunner
  class Failed < StandardError; end

  DEFAULT_CURRENCY = 'usd'

  class << self
    # Creates one payout for a publisher.
    #
    # @param publisher_profile [PublisherProfile]
    # @param user [User] who asked for it (recorded for the audit trail)
    # @param amount_cents [Integer]
    # @param connector [String] which B-Pay payout connector handles it
    # @param payout_method_id [String, nil] the destination the publisher configured with B-Pay
    # @param customer_id [String, nil]  defaults to the publisher's own customer id
    # @param confirm [Boolean] also call /confirm when the created payout asks for it
    # @param fulfill [Boolean] also call /fulfill once initiated (use only when money has actually moved)
    # @return [Payout]
    # @raise [Failed] B-Pay refused or was unreachable (the row is kept as `failed`)
    def create!(publisher_profile:, user:, amount_cents:, connector:,
                payout_method_id: nil, customer_id: nil, merchant_id: nil,
                currency: DEFAULT_CURRENCY, confirm: false, fulfill: false, description: nil)
      payout = Payout.create!(
        publisher_profile: publisher_profile, user: user,
        amount_cents: amount_cents, currency: currency, connector: connector,
        payout_method_id: payout_method_id, status: 'created',
        customer_id: customer_id.presence || "publisher-#{publisher_profile.id}"
      )

      result = BPayPayoutClient.create(
        amount_cents: payout.amount_cents, currency: payout.currency, connector: connector,
        customer_id: payout.customer_id, payout_method_id: payout_method_id,
        merchant_id: merchant_id, description: description,
        metadata: { payout_id: payout.id, publisher_profile_id: publisher_profile.id }
      )

      payout.update!(bpay_payout_id: result.payout_id, status: map_status(result.status), raw_response: result.raw.to_json)
      advance!(payout, confirm: confirm, fulfill: fulfill)
      payout
    rescue BPayPayoutClient::Error => e
      payout&.update(status: 'failed', failure_reason: e.message)
      Rails.logger.error("[PayoutRunner] #{e.class}: #{e.message}")
      raise Failed, e.message
    end

    # Processes a list of [publisher_profile, amount_cents] requests one by one, returning the rows that were
    # created and the errors that were not. This is the documented "bulk = Zealot's own loop" path.
    def bulk(requests, user:, connector:, **options)
      created = []
      errors = []
      requests.each do |request|
        profile, cents = request
        created << create!(publisher_profile: profile, user: user, amount_cents: cents,
                           connector: connector, **options)
      rescue Failed => e
        errors << { publisher_profile_id: profile&.id, amount_cents: cents, error: e.message }
      end
      { created: created, errors: errors }
    end

    # Re-reads a payout from B-Pay and writes whatever status it now reports. Idempotent.
    def refresh!(payout)
      result = BPayPayoutClient.retrieve(payout.bpay_payout_id)
      payout.update!(status: map_status(result.status), raw_response: result.raw.to_json)
      payout
    rescue BPayPayoutClient::Error => e
      payout.update(failure_reason: e.message)
      raise Failed, e.message
    end

    # POST /confirm — only for a payout B-Pay left in `requires_confirmation`.
    def confirm!(payout)
      result = BPayPayoutClient.confirm(payout.bpay_payout_id)
      payout.update!(status: map_status(result.status), confirmed_at: Time.current, raw_response: result.raw.to_json)
      payout
    rescue BPayPayoutClient::Error => e
      payout.update(failure_reason: e.message)
      raise Failed, e.message
    end

    # POST /fulfill — marks an initiated payout fulfilled once the money is out.
    def fulfill!(payout)
      result = BPayPayoutClient.fulfill(payout.bpay_payout_id)
      payout.update!(status: map_status(result.status), fulfilled_at: Time.current, raw_response: result.raw.to_json)
      payout
    rescue BPayPayoutClient::Error => e
      payout.update(failure_reason: e.message)
      raise Failed, e.message
    end

    # POST /cancel — only for a payout that has not moved yet.
    def cancel!(payout)
      raise Failed, 'this payout can no longer be cancelled' unless payout.cancellable?

      result = BPayPayoutClient.cancel(payout.bpay_payout_id)
      payout.update!(status: map_status(result.status), cancelled_at: Time.current, raw_response: result.raw.to_json)
      payout
    rescue BPayPayoutClient::Error => e
      payout.update(failure_reason: e.message)
      raise Failed, e.message
    end

    private

    # Confirm then (optionally) fulfil, only when the payout's current status asks for it.
    def advance!(payout, confirm:, fulfill:)
      confirm!(payout) if confirm && payout.status == 'requires_confirmation'
      fulfill!(payout) if fulfill && %w[initiated pending].include?(payout.status)
    end

    # Map B-Pay's payout status onto our vocabulary. Anything unknown is kept verbatim (downcased), so a
    # connector that adds a status is never silently mislabelled or lost.
    def map_status(status)
      normalized = status.to_s.strip.downcase
      return 'created' if normalized.blank?
      return normalized if Payout::STATUSES.include?(normalized)

      # B-Pay uses some upstream names we fold onto ours.
      case normalized
      when 'requires_confirmation' then 'requires_confirmation'
      when 'success', 'processed' then 'succeeded'
      when 'failure', 'errored' then 'failed'
      when 'initiated', 'pending', 'created', 'cancelled' then normalized
      else normalized
      end
    end
  end
end
