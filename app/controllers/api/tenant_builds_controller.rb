# frozen_string_literal: true

# Task 40n-f: The door distr's download button hits. It takes a build_id,
# finds the signed APK in the storage repo, and redirects the user to a
# short-lived GitHub download URL. No GitHub account is required by the user.
#
# Door auth (40n-f, second slice): the link must carry `expires` and `signature` query parameters that distr
# signed with the shared secret DISTR_LINK_SECRET (see TenantBuildLink). A browser following an email button
# cannot send an Authorization header, so the proof travels in the link itself. Anything unsigned, tampered,
# expired or signed for another build_id is refused before GitHub is contacted.
class Api::TenantBuildsController < ApplicationController
  # No `skip_before_action :verify_authenticity_token` here: ApplicationController already removes that
  # callback for every controller, and skipping a callback that is not defined raises ArgumentError when the
  # class loads, which kept the app from booting (the 40n-f, 40n-d3 and audit deploys all failed on it).

  before_action :require_signed_link, only: :download

  def download
    build_id = params[:build_id]
    url = TenantBuildDownload.new(build_id).call

    if url
      redirect_to url, allow_other_host: true
    else
      render plain: 'This build has expired, does not exist, or has been deleted. Please request a rebuild from distr.', status: :not_found
    end
  end

  private

  def require_signed_link
    case TenantBuildLink.verify(params[:build_id], params[:expires], params[:signature])
    when :ok
      nil
    when :expired
      render plain: 'This download link has expired. Please request a new link from distr.', status: :unauthorized
    when :unconfigured
      Rails.logger.error('TenantBuildsController: DISTR_LINK_SECRET is not set; the download door is closed')
      render plain: 'Downloads are not available right now.', status: :service_unavailable
    else
      render plain: 'This download link is not valid.', status: :unauthorized
    end
  end
end
