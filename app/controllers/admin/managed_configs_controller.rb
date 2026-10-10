# frozen_string_literal: true

# Z-P24 (enterprise device management; Play Console parity): the read-only panel that reports whether the
# organisation has set a managed-configuration policy and shows the document a device policy controller
# (Headwind MDM, Android Enterprise, any DPC) will read. Platform admins only.
#
# Read-only, like the SAML panel: the policy itself lives in Settings (the `managed_config` hash) so this page
# can never disagree with what `CatalogIndex::Publish` writes, and there is one place to edit it. The
# `download` action returns exactly the bytes published as `managed-config.json` (the same serializer), so an
# operator can hand the file straight to their provisioning tooling.
class Admin::ManagedConfigsController < ApplicationController
  def show
    authorize :managed_config, :show?
    load_panel
  end

  # GET /admin/managed_config.json
  def download
    authorize :managed_config, :show?
    render json: config.to_h
  end

  private

  def load_panel
    @title = t('admin.managed_config.show.title')
    @configured = config.configured?
    @document = config.to_h
    @source_tokens = CatalogIndex::ManagedConfig::SOURCE_TOKENS
  end

  def config
    @config ||= CatalogIndex::ManagedConfig.from_settings
  end
end
