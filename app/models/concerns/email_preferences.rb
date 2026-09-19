# frozen_string_literal: true

# Opt-outs for the platform's automated emails (Task 12).
#
#   deploys   — "a new build of your app was published"
#   notices   — errors, maintenance and per-app notices
#   campaigns — platform announcements / branding campaigns
#
# Every email links to a page (signed token, no login needed) where the user
# changes these. Payment receipts are transactional and have no switch.
module EmailPreferences
  extend ActiveSupport::Concern

  KINDS = %w[deploys notices campaigns].freeze
  TOKEN_PURPOSE = :email_preferences

  class_methods do
    # Users who may be emailed about `kind` right now: opted in and not locked.
    def wanting_email(kind)
      where("email_#{email_kind!(kind)}": true, locked_at: nil)
    end

    # Members of an app (owner + collaborators) who want `kind`.
    def wanting_email_for_app(app, kind)
      wanting_email(kind).where(id: Collaborator.unscoped.where(app_id: app.id).select(:user_id))
    end

    def find_by_email_preferences_token(token)
      find_signed(token.to_s, purpose: TOKEN_PURPOSE)
    end

    def email_kind!(kind)
      kind = kind.to_s
      raise ArgumentError, "unknown email kind: #{kind}" unless KINDS.include?(kind)

      kind
    end
  end

  def wants_email?(kind)
    self[:"email_#{self.class.email_kind!(kind)}"]
  end

  # Long-lived on purpose: an unsubscribe link in an old email must keep working.
  def email_preferences_token
    signed_id(purpose: TOKEN_PURPOSE)
  end
end
