# frozen_string_literal: true

# Task 37b-ii-k6: the four lifecycle steps of a tenant's `catalog_index` signing key, as
# admin-authenticated actions. The Render free plan has no shell (Task 27b-iv), so a rake task
# is not an option; each action just calls `TenantKeys::Lifecycle` (k3), which owns the
# locking, the state rules and the counter handling. Nothing here decides what is allowed.
#
# The private key is never rendered, returned or put in a flash: every action redirects back to
# the tenant's edit page (the k7 panel), and the only key facts that appear in a message are the
# public `key_id`. Routes live under `admin/tenants/:tenant_id/key`; there is no index or show.
class Admin::TenantKeysController < ApplicationController
  before_action :set_tenant

  # POST /admin/tenants/:tenant_id/key/generate
  def generate
    authorize key_scope, :generate?
    run_step(:generate!, 'generate')
  end

  # POST /admin/tenants/:tenant_id/key/stage_next
  def stage_next
    authorize key_scope, :stage_next?
    run_step(:stage_next!, 'stage_next')
  end

  # POST /admin/tenants/:tenant_id/key/promote
  def promote
    authorize key_scope, :promote?
    run_step(:promote!, 'promote')
  end

  # POST /admin/tenants/:tenant_id/key/retire   (add `force=1` to skip the overlap window)
  def retire
    authorize key_scope, :retire?
    force = params[:force] == '1'
    run_step(:retire!, 'retire', force: force)
  end

  private

  def set_tenant
    @tenant = Tenant.find(params[:tenant_id])
  end

  # A record-less policy target: the policy only needs to know the action, and this is never
  # persisted or rendered.
  def key_scope
    TenantSigningKey.new(tenant: @tenant)
  end

  def run_step(step, name, **kwargs)
    key = TenantKeys::Lifecycle.new(@tenant).public_send(step, **kwargs)
    Rails.logger.info("[tenant-keys] admin=#{current_user&.id} #{name} tenant=#{@tenant.tenant_id} key=#{key.key_id}" \
                      "#{' FORCED' if kwargs[:force]}")
    redirect_to edit_admin_tenant_path(@tenant), notice: t("admin.tenants.keys.success.#{name}", key_id: key.key_id)
  rescue TenantKeys::Lifecycle::OverlapNotElapsed
    redirect_to edit_admin_tenant_path(@tenant), alert: t('admin.tenants.keys.errors.overlap_not_elapsed',
                                                          ends_at: overlap_ends_at)
  rescue TenantKeys::Lifecycle::Error => e
    # Lifecycle's messages name the tenant and describe the refused state; they hold no key material.
    redirect_to edit_admin_tenant_path(@tenant), alert: e.message
  end

  # When the overlap window (measured from the promotion) ends, for the message above.
  def overlap_ends_at
    promoted_at = TenantSigningKey.active_for(@tenant)&.activated_at
    promoted_at ? (promoted_at + TenantKeys::Lifecycle::OVERLAP).utc.iso8601 : '-'
  end
end
