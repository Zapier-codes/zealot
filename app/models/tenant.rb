# frozen_string_literal: true

# Task 37b-ii-t1: one white-label operator served by this single Console deployment. Fields
# follow TenantConfig v1 (Storeapp `spec/tenant-config-schema.md`, Task 37a). Nothing reads this
# model yet: `Zealot::TenantResolver.registry` still returns no tenants (t2 wires it), so every
# request still resolves to the default tenant.
#
# Responds to `tenant_id` and `domains`, which is all the resolver asks of a record.
#
# The DEFAULT tenant is never a row: it is compiled into the resolver (a row claiming
# `tenant_id == 'default'` is dropped there), so it is refused here too.
class Tenant < ApplicationRecord
  # `tenant_id` is permanent and, once TENANT_BASE_DOMAIN is set, is also a hostname label
  # (`<tenant_id>.<base>`), so the labels a deployment uses for its own infrastructure are
  # refused up front (Task 37b-ii-t3; standard practice for any user-chosen subdomain).
  RESERVED_TENANT_IDS = ([Zealot::TenantResolver::DEFAULT_TENANT_ID] +
                         %w[www api admin app cdn console mail static assets]).freeze
  # Names that always mean "this machine", never a tenant's public domain.
  LOOPBACK_HOSTS = %w[localhost].freeze
  TENANT_ID_FORMAT = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
  COLOR_FORMAT = /\A#[0-9a-fA-F]{6}\z/
  SHA256_FORMAT = /\A[a-f0-9]{64}\z/
  DOMAIN_INPUT_FORMAT = /\A[^\s\/:@]+(:\d{1,5})?\.?\z/

  # Key material is never deleted with its tenant; what deleting a tenant means is 37b-iii's call.
  has_many :tenant_signing_keys, dependent: :restrict_with_error
  # Task 37b-iii-s2: a tenant that still owns apps cannot be destroyed (the database foreign key
  # backs this up). Apps are never deleted or silently moved to the default catalog with it.
  has_many :apps, dependent: :restrict_with_error

  # Permanent once created, same rule as the catalog index's `slug`.
  attr_readonly :tenant_id

  before_validation :normalize_fields

  validates :tenant_id, presence: true, format: { with: TENANT_ID_FORMAT },
                        exclusion: { in: RESERVED_TENANT_IDS }, uniqueness: true
  validate :tenant_id_unchanged, on: :update
  validates :display_name, presence: true
  validates :primary_color_hex, presence: true, format: { with: COLOR_FORMAT }
  validates :cdn_base, presence: true
  validates :logo_sha256, format: { with: SHA256_FORMAT }, allow_nil: true
  validates :logo_sha256, presence: true, if: -> { logo_url.present? }
  validate :urls_are_https
  validate :domains_are_valid_and_unclaimed
  validate :domains_avoid_reserved_hosts, if: :domains_changed?

  # The registry caches per process (t2); dropping this process's snapshot on every committed
  # write makes an admin's edit visible here at once. Other processes catch up within the TTL.
  after_commit { Zealot::TenantRegistry.reset! }

  class << self
    # Hosts that belong to the deployment itself and can never be a tenant's domain: a tenant
    # claiming one would make the resolver move the default tenant's own site to that tenant
    # (Task 37b-ii-t3). Read at validation time so a changed ZEALOT_DOMAIN applies at once.
    def reserved_hosts
      hosts = [ENV['ZEALOT_DOMAIN'], Zealot::TenantResolver.base_domain, *LOOPBACK_HOSTS, site_domain_setting]
      hosts.filter_map { |h| Zealot::TenantResolver.normalize_host(h) }.uniq
    end

    private

    # The admin-editable `site_domain` setting. A missing table or cache must not make a tenant
    # unsaveable, so any read error just leaves the env-derived hosts in force.
    def site_domain_setting
      defined?(::Setting) ? ::Setting.site_domain : nil
    rescue StandardError
      nil
    end
  end

  # One domain per line in the admin form; commas and any whitespace also separate entries.
  def domains_text
    Array(domains).join("\n")
  end

  def domains_text=(value)
    self.domains = value.to_s.split(/[\s,]+/).reject(&:blank?)
  end

  private

  def normalize_fields
    self.tenant_id = tenant_id.to_s.strip.downcase if tenant_id_changed? && tenant_id.present?
    %i[logo_url logo_sha256 catalog_index_base_url].each { |a| self[a] = self[a].presence }
    self.logo_sha256 = logo_sha256.downcase if logo_sha256
    self.domains = normalized_domains
  end

  # Same normalization the resolver applies to a request host, so a stored domain can only ever
  # match what the resolver would compute. The resolver's `normalize_host` is written for a
  # request Host header and cuts everything after the first ':', so it would turn a pasted URL
  # ("https://store.example.com") into the "domain" `https`. Stored entries must therefore look
  # like `host` or `host:port` BEFORE it is applied; anything else is kept as typed so the
  # validation below can refuse it instead of silently rewriting it.
  def normalized_domains
    Array(domains).filter_map do |raw|
      entry = raw.to_s.strip
      next if entry.empty?

      (entry.match?(DOMAIN_INPUT_FORMAT) && Zealot::TenantResolver.normalize_host(entry)) || entry
    end.uniq
  end

  def tenant_id_unchanged
    errors.add(:tenant_id, :readonly) if tenant_id_changed?
  end

  def urls_are_https
    { cdn_base: cdn_base, logo_url: logo_url, catalog_index_base_url: catalog_index_base_url }.each do |attr, value|
      next if value.blank?

      uri = URI.parse(value.to_s)
      errors.add(attr, :invalid) unless uri.is_a?(URI::HTTPS) && uri.host.present?
    rescue URI::InvalidURIError
      errors.add(attr, :invalid)
    end
  end

  def domains_are_valid_and_unclaimed
    bad = domains.reject { |d| Zealot::TenantResolver.normalize_host(d) == d }
    errors.add(:domains, :invalid) if bad.any?
    return if bad.any? || domains.empty?

    taken = Tenant.where.not(id: id)
                  .where('jsonb_exists_any(domains, ARRAY[?]::text[])', domains)
                  .flat_map(&:domains) & domains
    errors.add(:domains, :taken) if taken.any?
  end

  def domains_avoid_reserved_hosts
    clash = domains & self.class.reserved_hosts
    errors.add(:domains, :reserved, hosts: clash.to_sentence) if clash.any?
  end
end
