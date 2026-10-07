# frozen_string_literal: true

# Task 45f: the API twin of the category picker and the package-name field on the app's edit page, for a platform
# admin (AppPolicy#set_catalog_basics?), user token only. Like the editorial flags this SETS what is sent, so
# repeating a call is harmless; a change republishes the catalog index through App's own `after_commit`
# (`category` and `play_package_name` are both watched listing fields). Nothing is published from this action.
#
#   GET /api/apps/:app_id/catalog_basics  -> 200 the stored values and the allowed categories
#   PUT /api/apps/:app_id/catalog_basics  category=<value>  package_name=<id>   (send only what changes)
#                                         -> 200, or 422 saying why (unknown category, malformed or taken package)
#
# An empty value clears the field. `category` is one of App::CATEGORY_VALUES (for example `entertainment`, `tools`).
# Setting a package name also queues the Play preflight check the console form queues (App's own after_commit).
# The package name stays in the signed index (a reader needs it to tell whether an app is installed); whether a
# reader SHOWS it is the reader's choice.
class Api::Apps::CatalogBasicsController < Api::BaseController
  FIELDS = { 'category' => :category, 'package_name' => :play_package_name }.freeze

  before_action :validate_user_token
  before_action :set_app

  def show
    authorize @app, :set_catalog_basics?
    render json: report
  end

  def update
    authorize @app, :set_catalog_basics?
    attrs = FIELDS.select { |param, _| params.key?(param) }.to_h { |param, column| [column, params[param].to_s.strip.presence] }
    return render json: { error: 'send category and/or package_name' }, status: :unprocessable_entity if attrs.empty?

    @app.update!(attrs)
    render json: report
  end

  private

  def set_app
    @app = policy_scope(App).find(params[:app_id])
  end

  def report
    { app_id: @app.id, category: @app.category, package_name: @app.play_package_name,
      allowed_categories: App::CATEGORY_VALUES }
  end
end
