# frozen_string_literal: true

# Z-P10 / Task 50 (Play Console parity): the revenue report. Play shows a developer what their apps earned
# and what has been paid out; this is that page for the signed-in publisher — earnings from what Zealot
# actually charged (the `payments` table) and payouts to this publisher, folded by RevenueReport. Read-only:
# arranging an actual payout is PayoutsController.
class RevenuesController < ApplicationController
  before_action :authenticate_user!

  # GET /revenue
  def show
    authorize :revenue, :show?

    profile = current_user.publisher_profile
    # No profile yet means no apps and so nothing earned or paid; show the empty report rather than a
    # redirect, so the page explains itself.
    @profile = profile

    payments = profile ? Payment.where(app_id: profile.apps.select(:id)).includes(:app).to_a : []
    payouts = profile ? profile.payouts.recent_first.to_a : []

    @report = RevenueReport.new(payments: payments, payouts: payouts)
    @payouts_configured = BPayPayoutClient.configured?
    @title = t('.title')
  end
end
