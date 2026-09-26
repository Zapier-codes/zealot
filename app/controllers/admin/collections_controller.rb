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
    @collections = Collection.ordered
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
    @candidate_apps = App.where.not(id: @collection.apps.select(:id)).order(:name)
  end

  # PUT /admin/collections/:id
  def update
    authorize @collection

    if @collection.update(collection_params)
      redirect_to admin_collections_path, notice: t('activerecord.success.update', key: t('admin.collections.title'))
    else
      @candidate_apps = App.where.not(id: @collection.apps.select(:id)).order(:name)
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
    app = App.find_by(id: params[:app_id])
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

  def set_collection
    @collection = Collection.find(params[:id])
  end

  def collection_params
    params.require(:collection).permit(:slug, :name, :description)
  end
end
