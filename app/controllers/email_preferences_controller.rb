# frozen_string_literal: true

# One page, no login: the signed token from an email link identifies the user
# and lets them switch each kind of automated email on or off (Task 12).
class EmailPreferencesController < ApplicationController
  before_action :set_user

  def show; end

  def update
    attrs = EmailPreferences::KINDS.index_with do |kind|
      params.dig(:email_preferences, kind) == '1'
    end.transform_keys { |kind| "email_#{kind}" }

    @user.update_columns(attrs.merge(updated_at: Time.current))
    redirect_to email_preferences_path(params[:token]), notice: t('.saved'), status: :see_other
  end

  private

  def set_user
    @user = User.find_by_email_preferences_token(params[:token])
    return if @user

    render plain: t('email_preferences.invalid_link'), status: :not_found
  end
end
