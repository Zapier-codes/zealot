# frozen_string_literal: true

# Z-P10 / Task 50: the payout actions behind the revenue page. A signed-in user with a publisher profile may
# arrange a payout for their own published earnings and cancel one that has not moved yet. The money talks to
# B-Pay-backend through PayoutRunner, never directly — so the status mapping lives in one place.
class PayoutsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_profile
  before_action :set_payout, only: %i[cancel refresh]

  # POST /payouts
  def create
    authorize :payout, :create?

    if @profile.blank?
      return redirect_to revenue_path, alert: t('.need_profile')
    end

    unless BPayPayoutClient.configured?
      return redirect_to revenue_path, alert: t('.not_configured')
    end

    amount_cents = payout_amount_cents
    if amount_cents.nil? || amount_cents <= 0
      return redirect_to revenue_path, alert: t('.bad_amount')
    end

    connector = params.dig(:payout, :connector).to_s.strip
    if connector.blank?
      return redirect_to revenue_path, alert: t('.need_connector')
    end

    begin
      PayoutRunner.create!(
        publisher_profile: @profile, user: current_user,
        amount_cents: amount_cents, connector: connector,
        payout_method_id: params.dig(:payout, :payout_method_id).presence,
        currency: params.dig(:payout, :currency).presence || PayoutRunner::DEFAULT_CURRENCY,
        confirm: true
      )
    rescue PayoutRunner::Failed => e
      return redirect_to revenue_path, alert: t('.failed', reason: e.message)
    end

    redirect_to revenue_path, notice: t('.created')
  end

  # POST /payouts/:id/cancel
  def cancel
    authorize @payout, :cancel?

    if @payout.cancelled_at.present?
      return redirect_to revenue_path, alert: t('.already')
    end

    begin
      PayoutRunner.cancel!(@payout)
    rescue PayoutRunner::Failed => e
      return redirect_to revenue_path, alert: t('.failed', reason: e.message)
    end

    redirect_to revenue_path, notice: t('.cancelled')
  end

  # POST /payouts/:id/refresh — re-read the payout from B-Pay (the manual "check status" button).
  def refresh
    authorize @payout, :refresh?

    begin
      PayoutRunner.refresh!(@payout)
    rescue PayoutRunner::Failed => e
      return redirect_to revenue_path, alert: t('.failed', reason: e.message)
    end

    redirect_to revenue_path, notice: t('.refreshed')
  end

  private

  def set_profile
    @profile = current_user.publisher_profile
  end

  # The payout must belong to the signed-in publisher: a user may only act on their own.
  def set_payout
    @payout = @profile ? @profile.payouts.find_by(id: params[:id]) : nil
    redirect_to revenue_path, alert: t('.missing') if @payout.nil?
  end

  # The amount comes as dollars in a form field ("12.34"); convert to integer cents, or nil when unparseable.
  def payout_amount_cents
    raw = params.dig(:payout, :amount)
    return nil if raw.blank?

    (BigDecimal(raw.to_s) * 100).round
  rescue ArgumentError
    nil
  end
end
