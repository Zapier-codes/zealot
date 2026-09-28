# frozen_string_literal: true

# Task 31a (item 4): admin authoring for Collection, the top-level grouping
# CatalogIndex::Serializer#serialize_collections already publishes (see
# app/models/collection.rb). #add_app/#remove_app manage CollectionApp
# membership from the collection's edit page rather than through a separate
# nested resource -- there's nothing else a membership row needs yet (see
# CollectionApp's own comment about future per-membership data).
class Admin::CollectionsController < ApplicationController
  before_action :set_collection, only: %i[ edit update destroy add_app remove_app ]

  # GET /admin/collections
  def index
    # Task 37b-iii-s7c-3: through the policy scope (default host: all; tenant host: its own).
    @collections = policy_scope(Collection).ordered
    authorize @collections
  end

  # GET /admin/collections/new
  def new
    @collection = Collection.new
    authorize @collection
  end

  # POST /admin/collections
  def create
    @collection = Collection.new(collection_params)
    # A collection made on a tenant's host belongs to that tenant; on the default host it stays
    # the default catalog's (`nil`), exactly as before. Never taken from the request params.
    @collection.tenant = current_tenant
    authorize @collection

    if @collection.save
      redirect_to admin_collections_path, notice: t('activerecord.success.create', key: t('admin.collections.title'))
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /admin/collections/:id/edit
  def edit
    authorize @collection
    @candidate_apps = candidate_apps
  end

  # PUT /admin/collections/:id
  def update
    authorize @collection

    if @collection.update(collection_params)
      redirect_to admin_collections_path, notice: t('activerecord.success.update', key: t('admin.collections.title'))
    else
      @candidate_apps = candidate_apps
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /admin/collections/:id
  def destroy
    authorize @collection
    @collection.destroy
    redirect_to admin_collections_path, status: :see_other,
      notice: t('activerecord.success.destroy', key: t('admin.collections.title'))
  end

  # POST /admin/collections/:id/add_app
  def add_app
    authorize @collection, :update?
    # Task 37b-iii-s6a: only an app of the collection's own tenant can join it (CollectionApp refuses
    # a cross-tenant membership); an app of another tenant is simply not found here.
    app = same_tenant_apps.find_by(id: params[:app_id])
    @collection.apps << app if app && !@collection.apps.exists?(app.id)

    redirect_to edit_admin_collection_path(@collection)
  end

  # DELETE /admin/collections/:id/remove_app
  def remove_app
    authorize @collection, :update?
    @collection.collection_apps.where(app_id: params[:app_id]).destroy_all

    redirect_to edit_admin_collection_path(@collection), status: :see_other
  end

  private

  # Task 37b-iii-s6a: apps in the collection's own catalog (default tenant when it has none).
  def same_tenant_apps
    App.for_tenant(@collection.tenant)
  end

  def candidate_apps
    same_tenant_apps.where.not(id: @collection.apps.select(:id)).order(:name)
  end

  def set_collection
    # A cross-tenant id is simply not found (404), never a 403.
    @collection = policy_scope(Collection).find(params[:id])
  end

  def collection_params
    params.require(:collection).permit(:slug, :name, :description)
  end
end
