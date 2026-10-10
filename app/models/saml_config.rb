# frozen_string_literal: true

# Z-P18 (SSO/SAML half, Play Console parity): the SAML 2.0 single sign-on configuration.
#
# Play Console lets an enterprise sign its people in through the org's own identity provider (Okta, Entra
# ID, Keycloak, Authentik, ...) instead of a per-person password. Zealot already speaks OIDC and LDAP; SAML
# is the remaining enterprise protocol, and it is the one most IdPs still default to. This value object is
# the single place that decides whether a stored `Setting.saml` hash is *usable* and how its claim -> field
# map is handed to omniauth-saml. Keeping it here (pure: no Rails, no omniauth) means the rules are unit
# tested without booting a strategy or an IdP.
#
# Nothing here performs the SAML exchange -- omniauth-saml does that in the request path. This object answers
# two questions only: is the config complete enough to offer sign-in, and what does the attribute map look
# like. A value the operator has not set is `nil`/absent, never guessed.
module SamlConfig
  # The attributes a SAML assertion usually carries, mapped to the omniauth `info` fields the app already
  # reads (see UserOmniauth#from_omniauth). An operator can override any of these in `Setting.saml[:attribute_map]`
  # because IdPs disagree on the names ("email" vs "urn:oid:..."); the defaults cover the common Okta/Entra shape.
  DEFAULT_ATTRIBUTE_MAP = {
    'email' => %w[email mail urn:oid:0.9.2342.19200300.100.1.3],
    'name' => %w[displayName name urn:oid:2.16.840.1.113730.3.1.241],
    'first_name' => %w[firstName givenName urn:oid:2.5.4.42],
    'last_name' => %w[lastName sn surname urn:oid:2.5.4.4],
    'nickname' => %w[uid urn:oid:0.9.2342.19200300.100.1.1]
  }.freeze

  # The fields an operator may set. Anything else in the stored hash is ignored, so a stray key cannot smuggle
  # an unexpected option into the strategy.
  KNOWN_KEYS = %w[
    enabled idp_sso_url idp_slo_url idp_cert idp_metadata_url
    sp_entity_id sp_acs_url name_id_format uid_attribute attribute_map sign_authn_requests
  ].freeze

  module_function

  # Is this config complete enough to offer a SAML sign-in button and to start an AuthnRequest? "Enabled" is
  # not enough on its own: without an IdP SSO URL and the IdP's signing certificate omniauth-saml cannot
  # validate the assertion, and a login that can never succeed must not be offered. The SP entity id and ACS
  # URL are filled in by `with_defaults` from the request host when the operator has not set them.
  def configured?(config)
    config = (config || {})
    return false unless truthy?(config[:enabled]) || truthy?(config['enabled'])

    idp_sso_url(config).present? && idp_cert(config).present?
  end

  # The `attribute_statements` omniauth-saml wants: `info` field -> list of assertion attribute names to try.
  # The operator's `attribute_map` (a hash of field -> String or Array) is merged over the defaults, so a
  # mapping for one field does not drop the others. Blank entries are dropped.
  def attribute_statements(config)
    overrides = fetch(config, :attribute_map)
    return DEFAULT_ATTRIBUTE_MAP.transform_values(&:dup) unless overrides.is_a?(Hash)

    overrides.each_with_object(DEFAULT_ATTRIBUTE_MAP.transform_values(&:dup)) do |(field, names), out|
      next if field.to_s.blank?

      out[field.to_s] = Array(names).map(&:to_s).reject(&:blank?)
    end
  end

  # Fill the SP-side values omniauth-saml needs from the request host when the operator left them blank:
  # the SP entity id defaults to the metadata URL and the ACS URL to the omniauth callback. `host` is the
  # request's host (with any scheme already applied by the caller). Returns a new hash; nothing is mutated.
  def with_defaults(config, host:)
    config = (config || {}).symbolize_keys
    config[:sp_entity_id] ||= "#{host}/users/auth/saml/metadata"
    config[:sp_acs_url] ||= "#{host}/users/auth/saml/callback"
    config
  end

  def idp_sso_url(config)
    presence(fetch(config, :idp_sso_url) || fetch(config, :idp_metadata_url))
  end

  def idp_cert(config)
    presence(fetch(config, :idp_cert))
  end

  def fetch(config, key)
    return nil unless config.respond_to?(:[])

    config[key] || config[key.to_s]
  end

  def presence(value)
    value.to_s.strip.presence
  end

  def truthy?(value)
    value == true || %w[1 true on yes].include?(value.to_s.downcase)
  end
end
