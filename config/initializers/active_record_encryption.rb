# frozen_string_literal: true

# Active Record Encryption (built into Rails 7.1+, no extra gem) protects
# AndroidSigningKey's keystore material at rest. Configured from plain ENV
# vars rather than `config/credentials.yml.enc` so it works the same way
# on Render as the rest of this app's secrets (no session has access to
# the Rails master key to edit encrypted credentials blind).
#
# Generate the three values ONCE with:
#   bin/rails db:encryption:init
# and set them as ANTHROPIC_AR_ENCRYPTION_PRIMARY_KEY,
# ANTHROPIC_AR_ENCRYPTION_DETERMINISTIC_KEY, and
# ANTHROPIC_AR_ENCRYPTION_KEY_DERIVATION_SALT in the environment. Treat
# these exactly like the R2/Telegram credentials — losing them makes any
# already-encrypted keystore unrecoverable; rotating them requires
# re-encrypting existing AndroidSigningKey rows.
#
# Until these are set, any code path touching AndroidSigningKey's encrypted
# attributes will raise ActiveRecord::Encryption::Errors::Configuration —
# loudly, on purpose, rather than silently storing plaintext.
if ENV['ANTHROPIC_AR_ENCRYPTION_PRIMARY_KEY'].present?
  Rails.application.config.active_record.encryption.primary_key =
    ENV.fetch('ANTHROPIC_AR_ENCRYPTION_PRIMARY_KEY')
  Rails.application.config.active_record.encryption.deterministic_key =
    ENV.fetch('ANTHROPIC_AR_ENCRYPTION_DETERMINISTIC_KEY')
  Rails.application.config.active_record.encryption.key_derivation_salt =
    ENV.fetch('ANTHROPIC_AR_ENCRYPTION_KEY_DERIVATION_SALT')
end
