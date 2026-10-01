# frozen_string_literal: true

# Task 34a-1 (Storeapp leaf `f.xiv`): a per-app API token for a developer's own CI. It belongs to ONE
# app, is created by one user, and (34a-2) acts as that user on that app only, re-checked on every
# request. This model is the data and the pure rules; the auth path is Api::AppTokenAuth.
#
#   * Format: `zpa_` + 43 url-safe base64 characters (32 random bytes = 256 bits). `zpa_` is
#     "Zealot per-app", so a leaked secret is recognisable in a scan.
#   * Storage: only `Digest::SHA256.hexdigest(secret)`, unique-indexed. No bcrypt, no salt, no pepper:
#     the secret is 256 random bits, so guessing it is not the threat a slow hash defends against, and
#     the digest must be a deterministic lookup key (decision 34-1).
#   * The secret is returned once by `issue!` and never stored or logged by this model.
#   * Revoking is soft (`revoked_at`); the row stays for the audit log (34c).
#   * At most MAX_LIVE_PER_APP live (not revoked, not expired) tokens per app, so a rotation can
#     overlap and a runaway script cannot mint thousands. 10 is a choice, not a standard.
class AppApiToken < ApplicationRecord
  PREFIX = 'zpa_'
  # 32 bytes, url-safe base64 without padding.
  SECRET_BODY_LENGTH = 43
  SECRET_FORMAT = /\A#{PREFIX}[A-Za-z0-9_-]{#{SECRET_BODY_LENGTH}}\z/
  PUBLISH_SCOPE = 'publish'
  SCOPES = [PUBLISH_SCOPE].freeze
  MAX_LIVE_PER_APP = 10
  NAME_MAX_LENGTH = 100
  # `last_used_at` is written at most this often per token, so a busy CI job does not write on every call.
  LAST_USED_THROTTLE = 1.minute

  # What `issue!` returns: the stored row and the plaintext secret, which exists nowhere else.
  Issued = Struct.new(:token, :secret, keyword_init: true)

  belongs_to :app
  belongs_to :created_by, class_name: 'User', optional: true

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :token_digest, presence: true, uniqueness: true
  validates :last_four, presence: true
  validate :scopes_known
  validate :expiry_in_the_future, on: :create
  validate :live_cap_not_reached, on: :create

  # Not revoked and not expired. The one definition of "live", used for the cap and for lookup.
  scope :live, lambda {
    where(revoked_at: nil).where('app_api_tokens.expires_at IS NULL OR app_api_tokens.expires_at > ?', Time.current)
  }

  class << self
    def generate_secret
      PREFIX + SecureRandom.urlsafe_base64(32)
    end

    def digest_for(secret)
      Digest::SHA256.hexdigest(secret.to_s)
    end

    def well_formed?(secret)
      secret.is_a?(String) && SECRET_FORMAT.match?(secret)
    end

    # Mints a token for `app`. The cap is counted under a row lock on the app, so two issues at once
    # cannot both slip under it. Raises ActiveRecord::RecordInvalid when the name is blank, the expiry is
    # in the past, a scope is unknown or the app already has MAX_LIVE_PER_APP live tokens.
    # @return [Issued] the row and the plaintext secret, shown to the owner once
    def issue!(app:, name:, created_by:, expires_at: nil, scopes: SCOPES)
      secret = generate_secret
      token = nil
      transaction do
        App.lock.find(app.id)
        token = create!(
          app: app, name: name, created_by: created_by, expires_at: expires_at, scopes: Array(scopes),
          token_digest: digest_for(secret), last_four: secret[-4..]
        )
      end
      Issued.new(token: token, secret: secret)
    end

    # @return [AppApiToken, nil] the live token this secret belongs to. A malformed, unknown, revoked or
    #   expired secret all answer nil; the caller must not say which. Liveness is part of the same
    #   SELECT as the lookup, never read and compared afterwards.
    def authenticate(secret)
      return nil unless well_formed?(secret)

      live.find_by(token_digest: digest_for(secret))
    end
  end

  def live?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def scope?(scope)
    scopes.include?(scope.to_s)
  end

  def revoke!(now = Time.current)
    return self if revoked_at

    update!(revoked_at: now)
  end

  # Stamps `last_used_at`, at most once per LAST_USED_THROTTLE, in one UPDATE that also requires the
  # token to still be live (a token revoked a moment ago is not stamped as used). Returns true when a
  # row was written. It does not decide access: `authenticate` did.
  def record_use!(now = Time.current)
    due = self.class.where(id: id, revoked_at: nil)
                .where('last_used_at IS NULL OR last_used_at < ?', now - LAST_USED_THROTTLE)
                .where('expires_at IS NULL OR expires_at > ?', now)
    due.update_all(last_used_at: now).positive?
  end

  private

  def scopes_known
    list = Array(scopes)
    return errors.add(:scopes, :blank) if list.empty?

    errors.add(:scopes, :invalid) unless list.all? { |scope| SCOPES.include?(scope) } && list.uniq.size == list.size
  end

  def expiry_in_the_future
    errors.add(:expires_at, :invalid) if expires_at.present? && expires_at <= Time.current
  end

  def live_cap_not_reached
    return if app_id.nil?
    return if self.class.live.where(app_id: app_id).count < MAX_LIVE_PER_APP

    errors.add(:base, :too_many_live_tokens, max: MAX_LIVE_PER_APP,
                                             message: "An app can have at most #{MAX_LIVE_PER_APP} live API tokens")
  end
end
