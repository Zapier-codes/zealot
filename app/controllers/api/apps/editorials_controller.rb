# frozen_string_literal: true

# Task 42e: the API twin of the admin Featured and Editors' Pick toggles (Admin::AppsController). Platform
# admin only (AppPolicy#set_editorial_flags?), user token only. Unlike the console buttons, which flip the
# current value, this SETS the value you send, so repeating a call is harmless. A change republishes the
# catalog index through App's own `after_commit` (Task 42a); nothing is published from this action.
#
#   PUT /api/apps/:app_id/editorial   featured=true|false  and/or  editors_pick=true|false   -> 200 readiness report
#
# 422 when neither flag is sent or a value is not `true` or `false`.
class Api::Apps::EditorialsController < Api::BaseController
  FLAGS = %i[featured editors_pick].freeze
  VALUES = { 'true' => true, 'false' => false }.freeze

  before_action :validate_user_token
  before_action :set_app

  def update
    authorize @app, :set_editorial_flags?
    attrs = FLAGS.select { |flag| params.key?(flag) }.to_h { |flag| [flag, VALUES[params[flag].to_s.downcase]] }
    if attrs.empty? || attrs.value?(nil)
      return render json: { error: 'send featured and/or editors_pick as true or false' }, status: :unprocessable_entity
    end

    @app.update!(attrs)
    render json: StoreListingReadiness.call(@app.reload)
  end

  private

  def set_app
    @app = policy_scope(App).find(params[:app_id])
  end
end
