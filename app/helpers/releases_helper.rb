# frozen_string_literal: true

# Task 40h-c: the upload form's direct-to-storage mode. Both methods answer "plain form" (an empty hash) until
# `ReleaseUploadSession.enabled?` is true, so with the flag off the form renders exactly as it did before.
module ReleasesHelper
  DIRECT_UPLOAD_MESSAGE_KEYS = %w[opening sending finishing done failed send_failed].freeze

  # HTML options for the upload form: the Stimulus controller, its session URL and its localized messages.
  # Turbo is off for this form so the controller's own submit handling is the only one that runs.
  def direct_upload_form_html(channel)
    return {} unless ReleaseUploadSession.enabled?

    { data: { turbo: false,
              controller: 'direct-upload',
              action: 'submit->direct-upload#submit',
              direct_upload_session_url_value: channel_release_uploads_path(channel),
              direct_upload_messages_value: direct_upload_messages.to_json } }
  end

  def direct_upload_messages
    DIRECT_UPLOAD_MESSAGE_KEYS.index_with { |key| t("releases.direct_upload.#{key}") }
  end
end
