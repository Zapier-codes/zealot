# frozen_string_literal: true

# Task 31a (item 4 of the original slice list): the editorial surface for
# the outcome of ❓6. An app's own owner manages the app through the
# top-level AppsController (config/routes.rb's non-admin `resources :apps`);
# `featured`/`editors_pick` are store-owned data, not something an owner can
# set on themselves, so those two flags live here instead, behind the
# `authenticate :user, ->(user) { user.admin? }` gate the whole `admin`
# namespace already sits behind. See AppPolicy#set_editorial_flags?.
class Admin::AppsController < ApplicationController
  before_action :set_app, only: %i[ toggle_featured toggle_editors_pick ]

  # GET /admin/apps
  def index
    # Task 37b-iii-s7c-3: read through the policy scope (the one choke point): every app on the
    # default host, only the tenant's own apps on a tenant's host.
    @apps = policy_scope(App).order(:name)
    authorize @apps
  end

  # PUT /admin/apps/:id/toggle_featured
  def toggle_featured
    @app.update(featured: !@app.featured)
    redirect_to admin_apps_path, notice: t('.success', name: @app.name)
  end

  # PUT /admin/apps/:id/toggle_editors_pick
  def toggle_editors_pick
    @app.update(editors_pick: !@app.editors_pick)
    redirect_to admin_apps_path, notice: t('.success', name: @app.name)
  end

  private

  def set_app
    # A cross-tenant id is simply not found (404), never a 403.
    @app = policy_scope(App).find(params[:id])
    authorize @app, :set_editorial_flags?
  end
end
