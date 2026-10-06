# frozen_string_literal: true

# Task 40n-f: The door distr's download button hits. It takes a build_id,
# finds the signed APK in the storage repo, and redirects the user to a
# short-lived GitHub download URL. No GitHub account is required by the user.
class Api::TenantBuildsController < ApplicationController
  skip_before_action :verify_authenticity_token

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
