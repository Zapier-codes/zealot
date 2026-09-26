# frozen_string_literal: true

class AppsController < ApplicationController
  include AppArchived

  before_action :authenticate_user! unless Setting.guest_mode
  before_action :set_app, only: %i[show edit update destroy new_owner update_owner]
  before_action :set_selected_schemes_and_channels, only: %i[edit]
  before_action :process_scheme_and_channel, only: %i[create]
  before_action :set_owner, only: %i[ new_owner update_owner ]

  before_action -> { set_app_breadcrumbs(app: @app) }, only: %i[show edit update destroy new_owner update_owner]

  def index
    @title = t('.title')
    base_scope = manage_user_or_guest_mode? ? App.active : current_user.apps.active 
    base_scope = params[:search].present? ? base_scope.search_by_name(params[:search]) : base_scope
    @apps = params[:sort].present? ? base_scope.sort_by_name(params[:sort]) : base_scope
    authorize @apps if @apps.present?
  end

  def show
    @title = @app.name
  end

  def new
    @title = t('.title')
    @app = App.new
    authorize @app

    @app.schemes.build
  end

  def edit
    raise_if_app_archived!(@app)

    @title = t('.title')
  end

  def create
    @app = App.new(app_params)
    authorize @app
    unless @app.save
      # Bug fix (Task 20a): this used to be a bare `render :new,
      # status: :unprocessable_entity` with no format. The "New app" link
      # opens this form inside the #modal turbo frame, so Turbo sends an
      # Accept header that prefers turbo_stream. With no `apps/new.turbo_stream.slim`
      # template and no explicit format here, Rails tried to satisfy that
      # preference and raised ActionView::MissingTemplate on every invalid
      # submission — the request 500'd, the modal never updated, and (per
      # the modal_controller fix below) the dialog had already torn itself
      # down, so validation errors were never visible. Forcing :html makes
      # Rails render `apps/new.html.slim`, which (via render_modal) is
      # itself wrapped in `turbo_frame_tag :modal` — Turbo matches that
      # frame id in the response and swaps it into the still-open #modal
      # frame in place, which is the standard way Turbo re-displays
      # in-frame form errors.
      return render :new, status: :unprocessable_entity, formats: [:html]
    end

    create_owner
    create_schemes_and_channels

    # Bug fix (Task 20a): creation used to respond with turbo_stream,
    # appending the new app to `ul#apps` and staying on the index page.
    # `ul#apps` only renders when `@apps.present?` (see apps/index.html.slim),
    # so the very first app an account ever creates had no `#apps` target to
    # append to — Turbo silently dropped the stream, the record existed in
    # the database, but nothing appeared on screen until a manual reload.
    # Redirecting straight to the new app's own page sidesteps that target
    # entirely and matches how Play Console's "Create app" behaves: it lands
    # you on the new app's own dashboard, not back on a list. `_form.html.slim`
    # sets `data-turbo-frame="_top"` on this form (new/create only) so this
    # redirect breaks out of the `#modal` frame instead of trying to load the
    # app's page inside it.
    redirect_to @app, status: :see_other,
                notice: t('activerecord.success.create', key: "#{@app.name} #{t('apps.title')}")
  end

  def update
    raise_if_app_archived!(@app)

    unless @app.update(app_params)
      @title = t('apps.edit.title')
      set_selected_schemes_and_channels
      return render :edit, status: :unprocessable_entity
    end

    respond_to do |format|
      format.html { redirect_to apps_path }
      format.turbo_stream
    end
  end

  def destroy
    @app.destroy
    destroy_app_data

    respond_to do |format|
      format.any { redirect_to apps_path }
    end
  end

  def new_owner
    raise_if_app_archived!(@app)

    @title = t('.title')
  end

  def update_owner
    raise_if_app_archived!(@app)

    @title = t('apps.new_owner.title')
    @previous_user = @collaborator.user
    user_id = owner_params[:user_id]
    if @previous_user.id == user_id.to_i
      notice = t('activerecord.errors.messages.same_value', key: t('apps.new_owner.title'))
      return redirect_to @collaborator.app, notice: notice, status: :see_other
    end

    new_owner = User.find(user_id)
    if existed_collaborator = @app.collaborators.find_by(user: new_owner)
      existed_collaborator.destroy
    end

    return render :new_owner, status: :unprocessable_entity unless @collaborator.update(user: new_owner)

    notice = t('activerecord.success.update', key: t('apps.new_owner.title'))
    flash.now[:notice] = notice
    respond_to do |format|
      format.html { redirect_to @app }
      format.turbo_stream
    end
  end

  private

  def destroy_app_data
    require 'fileutils'

    app_binary_path = Rails.root.join('public', 'uploads', 'apps', "a#{@app.id}")
    FileUtils.rm_rf(app_binary_path) if Dir.exist?(app_binary_path)
  end

  def set_owner
    @collaborator = @app.collaborators.find_by(owner: true)
  end

  def create_owner
    @app.create_owner(current_user)
  end

  def create_schemes_and_channels
    @schemes.each do |scheme_name|
      scheme = @app.schemes.create(name: scheme_name)
      next if @channels.empty?

      @channels.each do |channel_name|
        scheme.channels.create name: channel_name, device_type: channel_name.downcase.to_sym
      end
    end
  end

  # def update_schemes_and_channels
  #   existed_schemes = @app.schemes.all

  #   @schemes.each do |scheme_name|
  #     scheme = @app.schemes.find_by(name: scheme_name)


  #     @channels.each do |channel_name|
  #       scheme.channels.create name: channel_name, device_type: channel_name.downcase.to_sym
  #     end
  #   end
  # end

  def set_selected_schemes_and_channels
    @schemes = []
    @channels = []
    @app.schemes.each do |scheme|
      @schemes << scheme.name

      channels = scheme.channels.pluck(:name)
      channels.each do |channel_name|
        @channels << channel_name unless @channels.include?(channel_name)
      end
    end
  end

  def process_scheme_and_channel
    @schemes = (app_params.delete(:scheme_attributes) || {}).fetch(:name, []).reject(&:empty?)
    @channels = (app_params.delete(:channel_attributes) || {}).fetch(:name, []).reject(&:empty?)
  end

  def set_app
    @app = App.find(params[:id])
    authorize @app
  end

  def app_params
    # Task 24: publisher_alias is only accepted from someone allowed to set
    # it; for everyone else it is silently not permitted (never mass-assigned).
    permitted = [:name, :play_package_name, :play_publish_track, :category]
    permitted << :publisher_alias if policy(@app || App.new).set_publisher_alias?

    @app_params ||= params.require(:app)
                          .permit(
                            *permitted,
                            scheme_attributes: { name: [] },
                            channel_attributes: { name: [] },
                          )
  end

  def render_not_found_entity_response(e)
    redirect_to apps_path, notice: t('apps.messages.failture.not_found_app', id: e.id)
  end

  def owner_params
    params.require(:collaborator).permit(:user_id)
  end
end
