# frozen_string_literal: true

# Task 42i: the hosted page where the card is typed, for a listing-fee payment started over the API
# (`POST /api/apps/:id/store_listing/pay` returns its link as `checkout_url`). No login: the signed, expiring
# token in the URL names one Payment and is the only credential, so anyone holding the link can pay that one
# invoice and do nothing else. The card goes from the page straight to B-PAY's SDK; Zealot never sees it.
# The page only starts the card step. The app goes live when B-PAY's signed webhook arrives
# (HyperswitchWebhooksController), never because this page was visited or redirected to.
class CheckoutsController < ApplicationController
  layout false

  def show
    @payment = Payment.find_by_checkout_token(params[:token].to_s)
    return render plain: 'This payment link is invalid or has expired. Start the payment again.', status: :not_found unless @payment&.listing_fee?

    @token = params[:token].to_s
    @state = state_for(@payment)
    @client_secret = @payment.client_secret
    @publishable_key = StoreListingPayment.publishable_key
    @sdk_url = StoreListingPayment.sdk_url
    @app = @payment.app
  end

  private

  def state_for(payment)
    case payment.status
    when 'succeeded' then :paid
    when 'pending' then payment.client_secret.present? ? :ready : :unavailable
    else :unavailable
    end
  end
end
