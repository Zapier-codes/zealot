# frozen_string_literal: true

# Z-P18 (SCIM half; Play Console parity): the console page that mints, lists and revokes the SCIM tokens an
# identity provider provisions with. Platform admins only (ScimTokenPolicy), under the routing-level admin
# gate as well. The plaintext secret is shown exactly once -- in the flash after a create -- and the page
# itself only ever reads `last_four`.
class Admin::ScimTokensController < ApplicationController
  def index
    authorize ScimToken
    @title = t('admin.scim_tokens.index.title')
    @scim_tokens = policy_scope(ScimToken).order(created_at: :desc)
    @scim_configured = SamlConfig.configured?(Setting.saml)
  end

  # POST /admin/scim_tokens
  def create
    @scim_token = ScimToken.new(scim_token_params)
    authorize @scim_token
    @scim_token.created_by = current_user

    issued = ScimToken.issue!(
      tenant: current_tenant,
      name: scim_token_params[:name],
      created_by: current_user,
      expires_at: parse_expiry(scim_token_params[:expires_at])
    )
    AuditEntry.record(
      action: 'created',
      subject: issued.token,
      actor: current_user,
      tenant: current_tenant,
      summary_i18n_key: 'admin.audit_entries.index.summary.scim_token',
      summary: "scim_token created name=#{issued.token.name} last_four=#{issued.token.last_four}",
      metadata: { kind: 'created', last_four: issued.token.last_four }
    )
    # The only time the plaintext exists: flash (not the URL, not a view variable that outlives the redirect).
    redirect_to admin_scim_tokens_path,
                notice: t('.created', secret: issued.secret, name: issued.token.name)
  rescue ActiveRecord::RecordInvalid => e
    @scim_tokens = policy_scope(ScimToken).order(created_at: :desc)
    @scim_configured = SamlConfig.configured?(Setting.saml)
    @title = t('admin.scim_tokens.index.title')
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :index, status: :unprocessable_entity
  end

  # DELETE /admin/scim_tokens/:id -- soft revoke; the row stays for the audit log.
  def destroy
    @scim_token = ScimToken.find(params[:id])
    authorize @scim_token
    @scim_token.revoke!
    AuditEntry.record(
      action: 'destroyed',
      subject: @scim_token,
      actor: current_user,
      tenant: current_tenant,
      summary_i18n_key: 'admin.audit_entries.index.summary.scim_token',
      summary: "scim_token revoked name=#{@scim_token.name} last_four=#{@scim_token.last_four}",
      metadata: { kind: 'removed', last_four: @scim_token.last_four }
    )
    redirect_to admin_scim_tokens_path, notice: t('.revoked')
  end

  private

  def scim_token_params
    params.require(:scim_token).permit(:name, :expires_at)
  end

  def parse_expiry(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
