# frozen_string_literal: true

# Task 31a (item 4): admin authoring for SponsoredSlot -- the dated
# placement window CatalogIndex::Serializer#sponsored_slots_for already
# reads per app. See app/models/sponsored_slot.rb: no separate ad creative
# is authored here, only the app and the date window.
class Admin::SponsoredSlotsController < ApplicationController
  before_action :set_sponsored_slot, only: %i[ edit update destroy ]

  # GET /admin/sponsored_slots
  def index
    @sponsored_slots = SponsoredSlot.includes(:app).order(starts_at: :desc)
    authorize @sponsored_slots
  end

  # GET /admin/sponsored_slots/new
  def new
    @sponsored_slot = SponsoredSlot.new
    authorize @sponsored_slot
  end

  # POST /admin/sponsored_slots
  def create
    @sponsored_slot = SponsoredSlot.new(sponsored_slot_params)
    authorize @sponsored_slot

    if @sponsored_slot.save
      redirect_to admin_sponsored_slots_path, notice: t('activerecord.success.create', key: t('admin.sponsored_slots.title'))
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /admin/sponsored_slots/:id/edit
  def edit
    authorize @sponsored_slot
  end

  # PUT /admin/sponsored_slots/:id
  def update
    authorize @sponsored_slot

    if @sponsored_slot.update(sponsored_slot_params)
      redirect_to admin_sponsored_slots_path, notice: t('activerecord.success.update', key: t('admin.sponsored_slots.title'))
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /admin/sponsored_slots/:id
  def destroy
    authorize @sponsored_slot
    @sponsored_slot.destroy
    redirect_to admin_sponsored_slots_path, status: :see_other,
      notice: t('activerecord.success.destroy', key: t('admin.sponsored_slots.title'))
  end

  private

  def set_sponsored_slot
    @sponsored_slot = SponsoredSlot.find(params[:id])
  end

  def sponsored_slot_params
    params.require(:sponsored_slot).permit(:app_id, :starts_at, :ends_at)
  end
end
