# frozen_string_literal: true

# Task 40n-f: The door distr's download button hits. It takes a build_id,
# finds the signed APK in the storage repo, and redirects the user to a
# short-lived GitHub download URL. No GitHub account is required by the user.
class Api::TenantBuildsController < ApplicationController
  # No `skip_before_action :verify_authenticity_token` here: ApplicationController already removes that
  # callback for every controller, and skipping a callback that is not defined raises ArgumentError when the
  # class loads, which kept the app from booting (the 40n-f, 40n-d3 and audit deploys all failed on it).

  def download
    build_id = params[:build_id]
    url = TenantBuildDownload.new(build_id).call

    if url
      redirect_to url, allow_other_host: true
    else
      render plain: 'This build has expired, does not exist, or has been deleted. Please request a rebuild from distr.', status: :not_found
    end
  end
end
