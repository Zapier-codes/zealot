# frozen_string_literal: true

# Z-P18 (SSO/SAML/SCIM half, Play Console parity): the bearer token an identity provider's SCIM client uses to
# provision and deprovision people in Zealot. Play Console's enterprise tier lets an org drive membership from
# its IdP; the provisioning half is SCIM 2.0, and this is the credential that authorises it.
#
# Same secret discipline as AppApiToken (Task 34a): `zsc_` prefix ("Zealot SCIM"), only the SHA-256 digest is
# stored (the secret is 256 random bits, so a fast hash is the right lookup key and a slow one would only make
# every provisioned user's request sluggish), the plaintext is returned once by `issue!` and never stored or
# logged, revoking is soft, and the token is tenant-scoped so one tenant's IdP can never provision into another
# tenant. A token with no tenant is platform-scoped and only a platform admin may mint it.
class ScimToken < ApplicationRecord
  PREFIX = 'zsc_'
  SECRET_BODY_LENGTH = 43
  SECRET_FORMAT = /\A#{PREFIX}[A-Za-z0-9_-]{#{SECRET_BODY_LENGTH}}\z/
  # The one scope SCIM needs; kept as a list so a future read-only provisioning token is additive.
  PROVISION_SCOPE = 'provision'
  SCOPES = [PROVISION_SCOPE].freeze
  MAX_LIVE_PER_TENANT = 5
  NAME_MAX_LENGTH = 100
  LAST_USED_THROTTLE = 1.minute

  Issued = Struct.new(:token, :secret, keyword_init: true)

  belongs_to :tenant, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :token_digest, presence: true, uniqueness: true
  validates :last_four, presence: true
  validate :scopes_known
  validate :expiry_in_the_future, on: :create
  validate :live_cap_not_reached, on: :create

  scope :live, lambda {
    where(revoked_at: nil).where('scim_tokens.expires_at IS NULL OR scim_tokens.expires_at > ?', Time.current)
  }

  # Deny by default, like the other tenant-scoped models: a tenant sees only its own tokens; the default host
  # (tenant nil) sees the platform-scoped ones.
  scope :for_tenant, ->(tenant) { where(tenant_id: tenant&.id) }

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

    # Mint a token for `tenant` (nil = platform-scoped). The cap is counted under a row lock on the tenant
    # when there is one, so two issues at once cannot both slip under it.
    def issue!(tenant:, name:, created_by:, expires_at: nil, scopes: SCOPES)
      secret = generate_secret
      token = nil
      transaction do
        Tenant.lock.find(tenant.id) if tenant
        token = create!(
          tenant: tenant, name: name, created_by: created_by, expires_at: expires_at, scopes: Array(scopes),
          token_digest: digest_for(secret), last_four: secret[-4..]
        )
      end
      Issued.new(token: token, secret: secret)
    end

    # @return [ScimToken, nil] the live token this secret belongs to, or nil for malformed/unknown/revoked/
    #   expired. The caller must not say which check failed.
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
    return if self.class.live.where(tenant_id: tenant_id).count < MAX_LIVE_PER_TENANT

    errors.add(:base, :too_many_live_tokens, max: MAX_LIVE_PER_TENANT,
                                             message: "A tenant can have at most #{MAX_LIVE_PER_TENANT} live SCIM tokens")
  end
end
