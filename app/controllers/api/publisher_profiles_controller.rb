# frozen_string_literal: true

# Task 42j: the publisher profile over the API, the last step of listing an app that was console-only. A store
# listing needs the owner to have one (`422 publisher_profile_required` otherwise).
#
#   GET /api/publisher_profile                       the token's own profile        (404 when none yet)
#   PUT /api/publisher_profile                       create it (201) or change it (200)
#   GET /api/users/:user_id/publisher_profile        a platform admin: any account's profile
#   PUT /api/users/:user_id/publisher_profile        a platform admin: create or change any account's profile
#
# Fields (top level or inside `publisher_profile`): kind (individual|company), display_name, legal_name, country,
# contact_email. User token in the `token` parameter. Same model and rules as the console page
# (PublisherProfilesController): the kind cannot be switched while one of the user's apps is live. Naming another
# user without being a platform admin is a 403.
class Api::PublisherProfilesController < Api::BaseController
  before_action :validate_user_token
  before_action :set_user

  def show
    profile = @user.publisher_profile
    return render json: { error: 'no publisher profile', code: 'publisher_profile_missing' }, status: :not_found unless profile

    render json: profile_json(profile)
  end

  def update
    profile = @user.publisher_profile || @user.build_publisher_profile
    created = profile.new_record?

    if profile.update(profile_params)
      render json: profile_json(profile), status: created ? :created : :ok
    else
      render json: { error: 'publisher profile is not valid', code: 'publisher_profile_invalid',
                     errors: profile.errors.to_hash }, status: :unprocessable_entity
    end
  end

  private

  def set_user
    if params[:user_id].present?
      @user = User.find(params[:user_id])
      authorize @user, :update?
    else
      @user = current_user
    end
  end

  def profile_params
    source = params[:publisher_profile].is_a?(ActionController::Parameters) ? params[:publisher_profile] : params
    source.permit(:kind, :display_name, :legal_name, :country, :contact_email)
  end

  def profile_json(profile)
    { id: profile.id, user_id: profile.user_id, kind: profile.kind, display_name: profile.display_name,
      legal_name: profile.legal_name, country: profile.country, contact_email: profile.contact_email,
      created_at: profile.created_at, updated_at: profile.updated_at }
  end
end
