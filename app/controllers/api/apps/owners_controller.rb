# frozen_string_literal: true

# Task 42e: the API twin of the console's "change owner" page (AppsController#update_owner). User token only.
# The same rule as the console: the current owner or a platform admin (AppPolicy#update_owner?), and an
# archived app is refused.
#
#   PUT /api/apps/:app_id/owner   user_id=<id>  or  email=<address>   -> 200 readiness report
#
# Idempotent: naming the user who already owns the app answers 200 with `changed: false`. If the new owner was
# already a collaborator of the app, that collaborator row is removed first (as the console does), then the
# owner row moves to the new user. 404 when no such user exists, 422 when neither parameter is given.
class Api::Apps::OwnersController < Api::BaseController
  before_action :validate_user_token
  before_action :set_app

  def update
    authorize @app, :update_owner?
    return render json: { error: 'app is archived', code: 'app_archived' }, status: :unprocessable_entity if @app.archived

    new_owner = find_user
    return render json: { error: 'user_id or email is required' }, status: :unprocessable_entity if new_owner == :missing
    return render json: { error: 'no such user' }, status: :not_found if new_owner.nil?

    collaborator = @app.owner
    return render json: { error: 'the app has no owner row' }, status: :unprocessable_entity unless collaborator

    changed = collaborator.user_id != new_owner.id
    changed && move_owner(collaborator, new_owner)
    render json: StoreListingReadiness.call(@app.reload).merge(changed: changed)
  end

  private

  def set_app
    @app = policy_scope(App).find(params[:app_id])
  end

  def find_user
    return User.find_by(id: params[:user_id]) if params[:user_id].present?
    return User.find_by('lower(email) = ?', params[:email].to_s.strip.downcase) if params[:email].present?

    :missing
  end

  def move_owner(collaborator, new_owner)
    Collaborator.transaction do
      @app.collaborators.where(user_id: new_owner.id).where.not(id: collaborator.id).destroy_all
      collaborator.update!(user: new_owner)
    end
  end
end
