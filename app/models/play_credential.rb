# frozen_string_literal: true

# Org-wide (task #7) Google Cloud service-account key used to authenticate
# calls to the Play Developer API. This is an API-auth credential, not a
# signing key — see PlayUploadKey for the (deliberately separate) key that
# signs the artifact bytes. The service account itself must be granted
# access under Play Console's own "API access" settings before any call
# made with it will succeed; nothing here can grant that access remotely,
# it's a manual Play Console step.
#
# `service_account_email` and `project_id` are parsed out of the uploaded
# JSON at validation time purely for display (so an admin looking at
# /admin/play_credential can confirm which service account is configured
# without downloading the key back out) — they are not secrets themselves
# and are not what's used to authenticate; the encrypted
# `service_account_json` is.
class PlayCredential < ApplicationRecord
  encrypts :service_account_json

  validates :service_account_json, presence: true
  validates :checksum, uniqueness: true, on: :create
  validate :only_one_record, on: :create
  validate :parse_service_account_json, on: :create

  before_validation :generate_checksum

  def self.current
    first
  end

  # Yields a local path to the decrypted service-account JSON, written to
  # a mode-0600 tempfile for the duration of the block — this is the form
  # `Google::Auth::ServiceAccountCredentials.make_creds` and the
  # `google-apis-androidpublisher_v3` client both expect. See
  # AndroidSigningKey/PlayUploadKey#with_keystore_files for the same
  # never-longer-lived-than-the-block pattern.
  def with_credentials_file
    Tempfile.create(['play-credentials', '.json']) do |file|
      file.chmod(0o600)
      file.write(service_account_json)
      file.flush
      yield file.path
    end
  end

  private

  def only_one_record
    errors.add(:base, :singleton) if PlayCredential.exists?
  end

  def parse_service_account_json
    parsed = JSON.parse(service_account_json)
    self.service_account_email = parsed['client_email']
    self.project_id = parsed['project_id']

    errors.add(:service_account_json, :missing_client_email) if service_account_email.blank?
  rescue JSON::ParserError => e
    errors.add(:service_account_json, :invalid_json, message: e.message)
  end

  def generate_checksum
    return if service_account_json.blank?

    self.checksum = Digest::SHA1.hexdigest(service_account_json)
  end
end
