# frozen_string_literal: true

# Z-P18 (SSO/SAML half; Play Console parity): the console panel that reports whether SAML single sign-on is
# configured and, when it is, shows the SP values the operator pastes into the identity provider. Platform
# admins only. Read-only: the configuration itself lives in Settings (the `saml` hash), the same place the
# other providers' settings live, so this page can never show a secret and there is one place to edit it.
#
# The metadata action renders the SP metadata XML an IdP can import directly (entity id, ACS URL, name-id
# format). It carries no secret, so it is a plain admin-only GET.
class Admin::SamlSettingsController < ApplicationController
  def show
    authorize :saml, :show?
    load_panel
  end

  # GET /admin/saml/metadata
  def metadata
    authorize :saml, :show?
    config = SamlConfig.with_defaults(Setting.saml, host: sp_host)
    render plain: metadata_xml(config), content_type: 'application/samlmetadata+xml'
  end

  private

  def load_panel
    @title = t('admin.saml_settings.show.title')
    @config = Setting.saml || {}
    @configured = SamlConfig.configured?(@config)
    @sp = SamlConfig.with_defaults(@config, host: sp_host)
    @attribute_statements = SamlConfig.attribute_statements(@config)
  end

  # Scheme + host of this request, so the SP entity id / ACS URL shown are the ones the IdP must be told.
  def sp_host
    "#{request.protocol}#{request.host_with_port}"
  end

  def metadata_xml(config)
    <<~XML
      <?xml version="1.0"?>
      <md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata"
                           entityID="#{ERB::Util.html_escape(config[:sp_entity_id])}">
        <md:SPSSODescriptor AuthnRequestsSigned="#{config[:sign_authn_requests] == true}"
                            WantAssertionsSigned="true"
                            protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
          <md:NameIDFormat>#{ERB::Util.html_escape(config[:name_id_format].presence || 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress')}</md:NameIDFormat>
          <md:AssertionConsumerService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
                                       Location="#{ERB::Util.html_escape(config[:sp_acs_url])}"
                                       index="1"/>
        </md:SPSSODescriptor>
      </md:EntityDescriptor>
    XML
  end
end
