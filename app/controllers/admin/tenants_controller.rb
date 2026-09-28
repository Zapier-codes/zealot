# frozen_string_literal: true

# Task 37b-ii-t3: admin authoring for Tenant (one white-label operator on this single
# deployment). No key material here (the key lifecycle is Admin::TenantKeysController, k6, shown by
# the k7 panel on the edit page) and no destroy: what deleting a
# tenant does to its apps and keys is 37b-iii's decision, so the route does not exist.
# Every committed write drops the registry cache through Tenant's after_commit.
class Admin::TenantsController < ApplicationController
  before_action :set_tenant, only: %i[ edit update ]

  # GET /admin/tenants
  def index
    @tenants = Tenant.order(:tenant_id)
    authorize @tenants
  end

  # GET /admin/tenants/new
  def new
    @tenant = Tenant.new
    authorize @tenant
  end

  # POST /admin/tenants
  def create
    @tenant = Tenant.new(tenant_params(creating: true))
    authorize @tenant

    if @tenant.save
      redirect_to admin_tenants_path, notice: t('activerecord.success.create', key: t('admin.tenants.title'))
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /admin/tenants/:id/edit
  def edit
    authorize @tenant
  end

  # PUT /admin/tenants/:id
  def update
    authorize @tenant

    if @tenant.update(tenant_params(creating: false))
      redirect_to admin_tenants_path, notice: t('activerecord.success.update', key: t('admin.tenants.title'))
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_tenant
    @tenant = Tenant.find(params[:id])
  end

  # `tenant_id` is permanent, so it is only ever accepted on create.
  def tenant_params(creating:)
    permitted = %i[ display_name primary_color_hex logo_url logo_sha256 cdn_base catalog_index_base_url domains_text ]
    permitted.unshift(:tenant_id) if creating
    params.require(:tenant).permit(*permitted)
  end
end
