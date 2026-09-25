# frozen_string_literal: true

# Task 32. Inbound webhook from B-PAY (self-hosted Hyperswitch): payment
# succeeded/failed, mandate created, refund processed. This is what
# actually flips an app live — it calls `App#go_live!`, the exact
# integration point `Apps::StoreListingsController#mark_paid`'s own comment
# names: "the payment slice will call App#go_live! ... and this action goes
# away." The checkout redirect is never trusted on its own, only this
# signed server-to-server call.
#
# `mark_paid` (the admin stand-in) is deliberately NOT removed in this
# slice — there is no confirmed client-side B-PAY checkout UI yet (see
# handover.md's Task 32 entry), so pulling the only working "go live" path
# before its replacement is verified end-to-end would leave the app with
# no way to go live at all. Remove it once `pay` below is confirmed working
# against real B-PAY traffic.
#
# ⚠️ SIGNATURE VERIFICATION IS NOT YET CONFIRMED AGAINST B-PAY'S ACTUAL
# WEBHOOK FORMAT. Hyperswitch's own webhook signing scheme (header name,
# HMAC vs. other algorithm, whether a timestamp is included) was not
# independently confirmed for this self-hosted instance — see
# handover.md's Task 32 entry. `signature_valid?` below implements a
# generic HMAC-SHA256-over-the-raw-body check against a configurable header
# name (`HYPERSWITCH_WEBHOOK_SIGNATURE_HEADER`, default
# `X-Webhook-Signature`) and a shared secret (`HYPERSWITCH_WEBHOOK_SECRET`).
# Before this goes live: trigger one real event from B-PAY's dashboard, log
# the actual headers it sends (a temporary `Rails.logger.info
# request.headers.to_h` at the top of `create` is enough), and adjust the
# header name / algorithm here to match — do not ship this unverified
# against production traffic.
class HyperswitchWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def create
    raw_body = request.raw_post

    unless signature_valid?(raw_body)
      Rails.logger.warn('[HyperswitchWebhooksController] signature check failed')
      return head :unauthorized
    end

    event = parse_event(raw_body)
    return head :bad_request if event.blank?

    handle_event(event)
    head :ok
  end

  private

  def signature_valid?(raw_body)
    secret = ENV['HYPERSWITCH_WEBHOOK_SECRET'].to_s.strip
    return true if secret.blank? && Rails.env.development? # local testing only

    return false if secret.blank?

    header_name = ENV['HYPERSWITCH_WEBHOOK_SIGNATURE_HEADER'].to_s.strip.presence || 'X-Webhook-Signature'
    provided = request.headers[header_name].to_s.delete_prefix('sha256=')
    return false if provided.blank?

    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)
    ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  def parse_event(raw_body)
    JSON.parse(raw_body)
  rescue JSON::ParserError
    nil
  end

  # B-PAY's exact event-type/payload shape is likewise unconfirmed (see the
  # class comment) — `event['event_type']` and `event.dig('content',
  # 'payment_id')` follow Hyperswitch's documented outgoing-webhook shape,
  # but haven't been checked against a real B-PAY payload yet.
  def handle_event(event)
    payment_id = event.dig('content', 'payment_id') || event['payment_id']
    payment = Payment.find_by(hyperswitch_payment_id: payment_id)
    unless payment
      Rails.logger.warn("[HyperswitchWebhooksController] no Payment for hyperswitch_payment_id=#{payment_id}")
      return
    end

    case event['event_type'].to_s
    when 'payment_succeeded'
      handle_succeeded(payment, payment_id, event)
    when 'payment_failed'
      payment.mark_failed!(raw: event.to_json)
    when 'refund_succeeded'
      # Deliberately manual-only — no code path calls this automatically.
      # Play's own registration fee is non-refundable regardless of
      # outcome; Task 32 mirrors that for B-PAY (handover.md ❓1). This
      # branch exists to record a refund an admin issued directly in B-PAY,
      # not to trigger one from Zealot.
      payment.mark_refunded!(raw: event.to_json)
    else
      Rails.logger.info("[HyperswitchWebhooksController] unhandled event_type=#{event['event_type']}")
    end
  end

  def handle_succeeded(payment, payment_id, event)
    mandate_id = event.dig('content', 'mandate_id')
    payment.mark_succeeded!(hyperswitch_payment_id: payment_id, mandate_id: mandate_id, raw: event.to_json)

    return unless payment.listing_fee?

    unless payment.app.go_live!
      # Not in awaiting_payment or suspended — e.g. an admin already used
      # mark_paid, or a duplicate webhook delivery. Not an error: log and
      # move on, matching Hyperswitch's own retry/at-least-once delivery
      # expectations.
      Rails.logger.info("[HyperswitchWebhooksController] app #{payment.app_id} " \
                        "already past awaiting_payment/suspended; go_live! no-op")
    end
  end
end
