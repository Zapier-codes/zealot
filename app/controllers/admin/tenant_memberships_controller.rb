# frozen_string_literal: true

# Task 37b-iii-s7c-7: add, re-role and remove the members of a tenant, from the admin console. Until
# this, `tenant_memberships` (s7c-0) could not be filled in, so no one could use a tenant's host.
# Routes live under `admin/tenants/:tenant_id/memberships`; there is no index or show, every action
# redirects back to the panel on the tenant's edit page. A member is an existing user found by
# email (this does not create accounts or send invitations).
#
# Rule kept here, not in the model: a tenant's only owner cannot be removed or demoted.
class Admin::TenantMembershipsController < ApplicationController
  before_action :set_tenant
  before_action :set_membership, only: %i[update destroy]

  # POST /admin/tenants/:tenant_id/memberships
  def create
    authorize TenantMembership.new(tenant: @tenant), :create?

    email = params[:email].to_s.strip.downcase
    user = User.find_by(email: email)
    return back(alert: t('admin.tenants.members.errors.user_not_found', email: email)) unless user
    return back(alert: t('admin.tenants.members.errors.invalid_role')) unless valid_role?

    membership = @tenant.tenant_memberships.new(user: user, role: role_param)
    if membership.save
      log('create', membership)
      back(notice: t('admin.tenants.members.success.create', email: user.email, role: role_name(membership)))
    else
      back(alert: t('admin.tenants.members.errors.already_member', email: user.email))
    end
  end

  # PATCH /admin/tenants/:tenant_id/memberships/:id
  def update
    authorize @membership, :update?

    return back(alert: t('admin.tenants.members.errors.invalid_role')) unless valid_role?
    if role_param != 'owner' && @membership.last_owner?
      return back(alert: t('admin.tenants.members.errors.last_owner', email: @membership.user.email))
    end

    @membership.update!(role: role_param)
    log('update', @membership)
    back(notice: t('admin.tenants.members.success.update', email: @membership.user.email, role: role_name(@membership)))
  end

  # DELETE /admin/tenants/:tenant_id/memberships/:id
  def destroy
    authorize @membership, :destroy?

    if @membership.last_owner?
      return back(alert: t('admin.tenants.members.errors.last_owner', email: @membership.user.email))
    end

    @membership.destroy!
    log('destroy', @membership)
    back(notice: t('admin.tenants.members.success.destroy', email: @membership.user.email))
  end

  private

  def set_tenant
    @tenant = Tenant.find(params[:tenant_id])
  end

  # Found through the tenant, so another tenant's membership id is a plain 404.
  def set_membership
    @membership = @tenant.tenant_memberships.find(params[:id])
  end

  def role_param
    params[:role].presence || 'member'
  end

  def valid_role?
    TenantMembership::ROLES.include?(role_param)
  end

  def role_name(membership)
    t("admin.tenants.members.roles.#{membership.role}")
  end

  def back(**flash)
    redirect_to edit_admin_tenant_path(@tenant), **flash
  end

  def log(action, membership)
    Rails.logger.info("[tenant-members] admin=#{current_user&.id} #{action} tenant=#{@tenant.tenant_id} " \
                      "user=#{membership.user_id} role=#{membership.role}")
  end
end
