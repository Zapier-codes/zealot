# frozen_string_literal: true

require 'json'

module CatalogIndex
  # Z-P24 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §6): the Console half of enterprise device
  # management. Play's enterprise story lets an organisation set app policy centrally (managed
  # configuration) and have a device policy controller (Headwind MDM, Android Enterprise, any DPC) hand it
  # to the client through `RestrictionsManager`. The client half is Storeapp's (`enterprise/ManagedConfig.kt`,
  # S-P3, already built); it reads those restrictions off the device. What was missing is the Console: the
  # place an operator *sets* the organisation's policy, and a document the org's provisioning tooling can
  # pull so the values a DPC pushes and the values Storeapp expects cannot drift.
  #
  # This class is the value object. It normalises a raw settings hash into exactly the three keys Storeapp's
  # `ManagedConfigRules` reads, with the SAME two rules that file states as its whole point:
  #
  #   1. a key the organisation did not set stays unset (`nil`) — the person's own choice is untouched;
  #   2. a value that cannot be understood is treated as unset, never guessed, so a typo in the org's config
  #      can never silently lock a person out.
  #
  # `source_tokens` are the canonical names: they are the `SourceId` enum entries in Storeapp, which its
  # parser matches case-insensitively, so publishing the exact names keeps the two ends in step.
  class ManagedConfig
    SCHEMA_VERSION = 1
    NOTE = 'Hidden by your organisation'

    # The canonical source names = Storeapp `SourceId` enum entries. Kept here so an operator (and the admin
    # panel) has one list to choose from; Storeapp ignores a name it does not know, so this can lag safely.
    SOURCE_TOKENS = %w[
      FDroid IzzyOnDroid GitHub GitLab Codeberg Flathub WinGet
      Zealot DStore Aurora Aptoide ApkPure
      MagiskAlt Googlers XposedRepo MagiskLegacy
    ].freeze

    MAX_PACKAGES = 200
    PACKAGE_FORMAT = /\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+\z/

    KEYS = %w[enabled_sources show_desktop_sources hidden_packages].freeze

    attr_reader :enabled_sources, :show_desktop_sources, :hidden_packages, :managed_keys

    def initialize(enabled_sources: nil, show_desktop_sources: nil, hidden_packages: [], managed_keys: [])
      @enabled_sources = enabled_sources
      @show_desktop_sources = show_desktop_sources
      @hidden_packages = hidden_packages
      @managed_keys = managed_keys
    end

    def self.from(raw)
      hash = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      managed = []

      sources = normalize_sources(hash['enabled_sources'])
      managed << 'enabled_sources' if sources[:set]

      desktop = normalize_boolean(hash['show_desktop_sources'])
      managed << 'show_desktop_sources' if !desktop.nil?

      hidden = normalize_packages(hash['hidden_packages'])
      managed << 'hidden_packages' unless hidden.empty?

      new(
        enabled_sources: sources[:value],
        show_desktop_sources: desktop,
        hidden_packages: hidden,
        managed_keys: managed
      )
    end

    # Reads the org policy from Settings (`Setting.managed_config`), the same place the SAML/SCIM enterprise
    # settings live. Duck-typed so the serializer/spec can pass a plain hash unchanged.
    def self.from_settings(setting = Setting.managed_config)
      from(setting || {})
    end

    # True when an organisation has actually set any policy. When false there is nothing to publish and the
    # client is unmanaged (hard-coded defaults).
    def configured? = managed_keys.any?

    # The document the provisioning tooling pulls (and an operator can eyeball). Every key is present —
    # unset ones are `null`, which is exactly "leave the person's choice" on the client — plus the list of
    # keys the org really set, so a reader never has to infer it.
    def to_h
      {
        'schema_version' => SCHEMA_VERSION,
        'source' => 'zealot',
        'note' => NOTE,
        'managed_keys' => managed_keys,
        'config' => {
          'enabled_sources' => enabled_sources,
          'show_desktop_sources' => show_desktop_sources,
          'hidden_packages' => hidden_packages
        }
      }
    end

    def to_json(*args) = JSON.generate(to_h, *args)

    # {set: bool, value: Array|nil}. `set` distinguishes "not configured" (nil) from "configured to none"
    # ([]), the same blank-vs-`none` rule Storeapp's parser uses.
    def self.normalize_sources(value)
      tokens = tokenize(value)
      return { set: false, value: nil } if tokens.empty?
      return { set: true, value: [] } if tokens.any? { |t| %w[none off].include?(t) }

      known = tokens.filter_map { |t| SOURCE_TOKENS.find { |name| name.casecmp?(t) } }.uniq
      known.empty? ? { set: false, value: nil } : { set: true, value: known }
    end

    def self.normalize_boolean(value)
      case value.to_s.strip.downcase
      when 'true', '1', 'yes', 'on' then true
      when 'false', '0', 'no', 'off' then false
      end
    end

    def self.normalize_packages(value)
      Array(value.is_a?(String) ? value.split(/[,;\s]+/) : value)
        .map { |p| p.to_s.strip }
        .select { |p| PACKAGE_FORMAT.match?(p) }
        .uniq
        .first(MAX_PACKAGES)
    end

    def self.tokenize(value)
      Array(value.is_a?(String) ? value.split(/[,;\s]+/) : value)
        .map { |t| t.to_s.strip.downcase }
        .reject(&:empty?)
    end
  end
end
