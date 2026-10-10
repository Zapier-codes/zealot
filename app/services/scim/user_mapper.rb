# frozen_string_literal: true

# Z-P18 (SCIM half, Play Console parity): the pure translation between a Zealot `User` (+ its membership in a
# tenant) and the SCIM 2.0 User resource an identity provider's provisioning client speaks. Play Console's
# enterprise tier drives org membership from the IdP; SCIM is how that is done, and this object is the whole
# mapping so the request path (Scim::UsersController) stays thin and this can be unit tested without a server.
#
# Everything a SCIM client can change about a provisioned user is here: the username (the email), the display
# name parts, the active flag (a de-provision becomes active=false -> the membership is removed, the account is
# locked, never destroyed -- an audit trail and the person's own history must survive their leaving the org).
# A field the client did not send is left as it is, never blanked, so a PATCH that only flips `active` cannot
# wipe a name.
module Scim
  module UserMapper
    USER_SCHEMA = 'urn:ietf:params:scim:schemas:core:2.0:User'
    LIST_RESPONSE_SCHEMA = 'urn:ietf:params:scim:api:messages:2.0:ListResponse'

    module_function

    # A SCIM User resource built from `user` and, when present, the user's membership in `tenant`.
    # `active` is the membership state: a user with no membership in this tenant reads as inactive, because
    # from the IdP's point of view they are not provisioned into this org.
    def to_resource(user, tenant: nil, membership: nil)
      membership ||= tenant && user.tenant_memberships.find_by(tenant_id: tenant.id)
      {
        'schemas' => [USER_SCHEMA],
        'id' => user.id.to_s,
        'externalId' => nil,
        'userName' => user.email,
        'name' => {
          'givenName' => user.username,
          'familyName' => nil,
          'formatted' => user.username
        },
        'displayName' => user.username.presence || user.email,
        'emails' => [{ 'value' => user.email, 'primary' => true }],
        'active' => membership.present?,
        'meta' => {
          'resourceType' => 'User',
          'created' => user.created_at&.utc&.iso8601,
          'lastModified' => user.updated_at&.utc&.iso8601,
          'location' => "/scim/v2/Users/#{user.id}"
        }
      }
    end

    # A SCIM ListResponse envelope. `total_results` is the unpaged count, `items_per_page`/`start_index` the
    # page SCIM's own paging convention uses.
    def list_response(resources, total: nil, start_index: 1, items_per_page: nil)
      {
        'schemas' => [LIST_RESPONSE_SCHEMA],
        'totalResults' => total || resources.size,
        'startIndex' => start_index,
        'itemsPerPage' => items_per_page || resources.size,
        'Resources' => resources
      }
    end

    # The attributes a SCIM create/extract yields, as a plain hash of Zealot field names. Only keys the client
    # actually sent are present, so a PATCH can merge without blanking anything. `userName` and the primary
    # email are the same value; the first non-blank wins.
    def attributes_from(payload)
      payload = payload.to_h
      email = extract_email(payload)
      name = payload['name'].is_a?(Hash) ? payload['name'] : {}

      attrs = {}
      attrs[:email] = email if email.present?
      given = name['givenName'].presence || payload['displayName'].presence
      attrs[:username] = given.to_s if given.present?
      attrs[:active] = payload['active'] unless payload['active'].nil?
      attrs
    end

    # The primary email from a SCIM payload: `userName` first (the SCIM spec's own user identifier), then the
    # primary entry of `emails`, then the first entry. nil when none is present.
    def extract_email(payload)
      direct = payload['userName'].presence
      return direct if direct.present?

      emails = Array(payload['emails']).select { |e| e.is_a?(Hash) }
      primary = emails.find { |e| e['primary'].to_s == 'true' } || emails.first
      primary && primary['value'].presence
    end
  end
end
