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
