# frozen_string_literal: true

# Task 25: the signed-in user's publisher profile (Individual / Company) —
# a singular resource (config/routes.rb: `resource :publisher_profile`). Every
# user only ever touches their own; there is no id in the URL.
class PublisherProfilesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_profile
  before_action :redirect_to_edit_if_exists, only: %i[new create]
  before_action :redirect_to_new_if_missing, only: %i[edit update]

  # GET /publisher_profile/new
  def new
    @profile = current_user.build_publisher_profile
    @title = t('.title')
  end

  # POST /publisher_profile
  def create
    @profile = current_user.build_publisher_profile(profile_params)

    if @profile.save
      redirect_to after_save_path, notice: t('.notice')
    else
      @title = t('publisher_profiles.new.title')
      render :new, status: :unprocessable_entity
    end
  end

  # GET /publisher_profile/edit
  def edit
    @title = t('.title')
  end

  # PATCH /publisher_profile
  def update
    if @profile.update(profile_params)
      redirect_to after_save_path, notice: t('.notice')
    else
      @title = t('publisher_profiles.edit.title')
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_profile
    @profile = current_user.publisher_profile
  end

  def redirect_to_edit_if_exists
    redirect_to edit_publisher_profile_path(return_to: params[:return_to].presence) if @profile
  end

  def redirect_to_new_if_missing
    redirect_to new_publisher_profile_path(return_to: params[:return_to].presence) unless @profile
  end

  # Back to where the user came from (e.g. the store listing page) — only ever
  # a path on this site (url_from rejects anything off-host).
  def after_save_path
    url_from(params[:return_to]) || edit_publisher_profile_path
  end

  def profile_params
    params.require(:publisher_profile).permit(:kind, :display_name, :legal_name, :country, :contact_email)
  end
end
