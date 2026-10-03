# frozen_string_literal: true

# Task 34d-1: metadata only, matching /admin/android_signing_key's show page. Never the keystore and never
# either password (all three are encrypted at rest in the model, and are the credentials that sign every
# release this organization ships). `checksum` is the non-secret SHA1 of the keystore bytes that
# Release#signing_key_checksum already records, so it identifies a key without exposing it.
class Api::AndroidSigningKeySerializer < ApplicationSerializer
  attributes :id, :filename, :key_alias, :checksum, :created_at
end
