# frozen_string_literal: true

# Metadata-only shape, matching /admin/play_credential's show view — never
# exposes service_account_json (encrypted at rest via `encrypts` in the
# model; not something any API response should hand back out even
# decrypted, since it's the credential that authenticates every Play
# Developer API call this app makes).
class Api::PlayCredentialSerializer < ApplicationSerializer
  attributes :id, :service_account_email, :project_id, :checksum, :created_at
end
