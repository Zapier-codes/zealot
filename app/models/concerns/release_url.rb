# frozen_string_literal: true

module ReleaseUrl
  extend ActiveSupport::Concern

  included do
    include Rails.application.routes.url_helpers
  end

  def download_url
    download_release_url(id)
  end

  # Task 27d-c: the stable icon endpoint (Task 27d-b), built on the same host as `download_url`.
  def icon_download_url
    icon_download_release_url(id)
  end

  # Z-P13: the update-delta endpoint for a patch made from `from_version_code`. The patch bytes are served
  # from storage by the same controller that would serve the full file, so a client downloads it the same
  # way. `to_query` is not used because the value never contains characters a path segment cannot carry.
  def delta_download_url(from_version_code)
    delta_download_release_url(id, from: from_version_code)
  end

  def install_url
    return download_url unless platform == 'iOS'

    ios_url = channel_release_install_url(channel.slug, id)
    "itms-services://?action=download-manifest&url=#{ios_url}"
  end

  def release_url
    friendly_channel_release_url(channel, self)
  end

  def qrcode_url(**options)
    channel_release_qrcode_url(channel, self, **options)
  end
end
