# frozen_string_literal: true

# Z-P22: the deep-link verification checker page for one app. It runs DeepLinkCheck, which reads the
# app's package, its signing certificate (from the newest Android release's teardown metadata) and the
# hosts its deep links declare, then checks each host's `/.well-known/assetlinks.json` with
# AssetLinks::Verifier. Read-only: it never writes to the app's own sites.
#
# The person opens this page; the check is a live read, so pressing "Re-check" runs it again.
class Apps::DeepLinkVerificationsController < ApplicationController
  before_action :authenticate_user! unless Setting.guest_mode
  before_action :set_app

  # GET /apps/:app_id/deep_link_verification
  def show
    authorize @app, :show?

    @title = t('apps.deep_link_verifications.title')
    @result = DeepLinkCheck.new(@app).call
    @blocked_reason = blocked_reason
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  # Why the check cannot run, in the order the page reads it. Nil when it can.
  def blocked_reason
    return :no_package if @result.package_name.blank?
    return :no_certificate if @result.sha256.blank?
    return :no_hosts if @result.hosts.empty?

    nil
  end
end
