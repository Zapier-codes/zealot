# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'

module FdroidIndex
  # Z-P15 (Play Console parity; docs/PARITY-KANBAN.md): render Zealot's live catalog in the F-Droid
  # repository format (index-v2 + the `entry.json` entry point), so an F-Droid-style client (F-Droid,
  # Droid-ify, Neo Store, Obtainium) can read our apps. The Zealot signed index stays the trust anchor
  # (Storeapp and D-Store read that); this is a second, additional view for reach into the F-Droid
  # ecosystem, exactly as `docs/UNOFFICIAL-ROUTES.md` records ("nothing to write but a job").
  #
  # ## What is written here, and what is not
  # This class produces the two JSON documents and nothing else:
  #   * `index_json`  -- index-v2, the full catalog
  #   * `entry_json`  -- entry.json, the small, signed entry point that points at index-v2 by sha256/size
  # The two must agree: `entry.json.index.sha256`/`.size` are the digest and byte length of exactly the
  # `index_json` bytes produced here, and the spec asserts that (see `spec/services/fdroid_index`). Signing
  # (the signed `entry.jar`) and the Pages publish are the NEXT slice (Z-P15b), deliberately not here: this
  # file has no Rails and no OpenSSL, so it is a pure, unit-testable mapping like `CatalogIndex::Serializer`.
  #
  # ## The format, checked against the source, not guessed
  # Read from fdroidserver (`fdroidserver/index.py`, `fdroidserver/signindex.py`, `fdroidserver/update.py`:
  # `METADATA_VERSION = 30000`) and from f-droid.org's own live `entry.json`/`index-v2.json` this session:
  #   * index-v2 top level: `{ "repo": {...}, "packages": { "<packageName>": {metadata, versions} } }`
  #   * `entry.json`: `{ timestamp (ms), version: 30000, maxAge, index: { name, sha256, size, numPackages } }`
  #   * a `versions` value is keyed by the APK's sha256 and carries `added`, `file {name, sha256, size}` and
  #     `manifest { versionName, versionCode (a NUMBER), usesSdk {minSdkVersion,targetSdkVersion},
  #     signer {sha256: [...]}, usesPermission: [{name}], nativecode: [...] }`
  #   * all human text is a locale map, e.g. `"name": {"en-US": "..."}`
  #
  # ## Duck-typed, and why
  # Every read is behind `respond_to?`, exactly like `CatalogIndex::Serializer`: a Struct fixture (no
  # ActiveRecord) serializes the same way a real `App` does, so the mapping can be exercised on its own and
  # an app column added later cannot break this by its absence.
  #
  # ## Flagged, not decided here (see the kanban card)
  # The APK's `file.name` is published as the release's absolute, stable download URL (Zealot's own
  # `/download/releases/:id`). F-Droid's own index uses a repo-relative path, but the client resolves the
  # name against the repo `address` and an absolute URL wins that resolution, so the APK stays served from
  # Zealot and is never mirrored into the Pages repo. This one assumption (that the F-Droid client honours
  # an absolute `file.name`) is the thing Z-P15b must confirm against a real client before this ships; it is
  # called out here rather than assumed silently.
  # Z-P15c reconciles the second flagged item: with a `signer_fingerprint` given (the org key's certificate
  # SHA-256, `AndroidSigningKey#certificate_sha256`), `manifest.signer.sha256` and each package's
  # `metadata.preferredSigner` carry a real certificate fingerprint, the value an F-Droid client compares an
  # installed APK against and the same value `signer_index_json` lists. Without one the serializer falls back
  # to the release's `signing_key_checksum` (SHA-1 of the keystore), which is not a certificate SHA-256; that
  # fallback exists only so a keyless run still serializes and it is what the card flags when it appears.
  class Serializer
    # The F-Droid index-v2 format version, from fdroidserver `METADATA_VERSION` (30000), not guessed.
    FORMAT_VERSION = 30_000
    # How long a client may keep this index before re-fetching; F-Droid's own entry.json carries 14.
    DEFAULT_MAX_AGE_DAYS = 14
    # F-Droid's own locales are BCP-47; our listings are one language today, published as en-US like everything
    # else in the index. A machine translation (Z-P21) adds that locale's text beside it.
    DEFAULT_LOCALE = 'en-US'

    Result = Struct.new(:index_json, :entry_json, :signer_index_json, :generated_at, :package_count, keyword_init: true)

    # @param apps [Array, #to_a] the published apps (same set the signed index uses: `CatalogIndex::Signer.default_apps`)
    # @param signer_fingerprint [String, nil] Z-P15c: the org signing key's certificate SHA-256, lower-case hex
    #   (AndroidSigningKey#certificate_sha256). When given it is published as `manifest.signer.sha256[]` and as
    #   each package's `metadata.preferredSigner` — F-Droid's real field and the value its signer-index lists,
    #   which is what its client compares an installed APK's signer against. When nil (no key configured, or a
    #   fixture) the serializer falls back to the release's own `signing_key_checksum`, which is *not* a
    #   certificate SHA-256 and would not verify in an F-Droid client; that fallback is kept only so a
    #   keyless run still serializes, and it is what the card flags as "not reconciled" when it appears.
    def initialize(apps, now: Time.now.utc, repo_name: 'Zealot', repo_description: nil,
                   repo_address: nil, repo_icon: nil, max_age_days: DEFAULT_MAX_AGE_DAYS,
                   signer_fingerprint: nil)
      @apps = apps.respond_to?(:play_package_name) ? [apps] : apps.to_a
      @now = now
      @repo_name = repo_name
      @repo_description = repo_description
      @repo_address = repo_address
      @repo_icon = repo_icon
      @max_age_days = max_age_days
      @signer_fingerprint = signer_fingerprint.to_s.strip.downcase.presence
    end

    def self.call(apps, **opts)
      new(apps, **opts).call
    end

    def call
      timestamp = ms(@now)
      packages = @apps.each_with_object({}) do |app, out|
        package = serialize_app(app)
        out[package[:package_name]] = package[:body] if package
      end

      index = { 'repo' => serialize_repo(timestamp), 'packages' => packages }
      index_json = "#{JSON.pretty_generate(index)}\n"
      entry = {
        'timestamp' => timestamp,
        'version' => FORMAT_VERSION,
        'maxAge' => @max_age_days,
        'index' => {
          'name' => '/index-v2.json',
          'sha256' => Digest::SHA256.hexdigest(index_json),
          'size' => index_json.bytesize,
          'numPackages' => packages.size
        }
      }
      Result.new(index_json: index_json, entry_json: "#{JSON.pretty_generate(entry)}\n",
                 signer_index_json: signer_index_json(packages), generated_at: @now, package_count: packages.size)
    end

    private

    # Z-P15c: F-Droid's signer index (`/repo/signer-index.json`), `{ "<packageName>": { "signer": "<sha256>" } }`.
    # Read from f-droid.org's own live file this session (552 KB, 4577 packages, shape confirmed). It is the
    # source of truth that maps a package to the certificate that must sign its APK. We publish one entry per
    # package, the org certificate: our whole catalog is signed by the one AndroidSigningKey, so every package
    # maps to the same fingerprint. A package with no resolvable certificate (no key configured and no release
    # checksum) is left out rather than given a null signer.
    def signer_index_json(packages)
      fingerprint = @signer_fingerprint || packages.keys.filter_map { |name| release_signer_fingerprint(name) }.first
      return nil if fingerprint.nil?

      entries = packages.keys.sort.each_with_object({}) { |name, out| out[name] = { 'signer' => fingerprint } }
      "#{JSON.pretty_generate(entries)}\n"
    end

    # The first release checksum seen for a package, when no org certificate was supplied; see the
    # `signer_fingerprint` note on the constructor for why this is a fallback and not the real value.
    def release_signer_fingerprint(package_name)
      app = @apps.find { |a| text(a, :play_package_name) == package_name }
      return nil unless app

      releases_for(app).filter_map { |r| signer_for(r) }.first
    end

    def serialize_repo(timestamp)
      repo = {
        'name' => { DEFAULT_LOCALE => @repo_name },
        'address' => @repo_address,
        'timestamp' => timestamp
      }
      repo['description'] = { DEFAULT_LOCALE => @repo_description } if @repo_description.present?
      repo['icon'] = { DEFAULT_LOCALE => @repo_icon } if @repo_icon.is_a?(Hash)
      repo
    end

    # @return [Hash, nil] {package_name:, body:} or nil for an app with no package name (F-Droid keys a package
    #   by its package name; an app without one cannot be addressed, so it is left out, never guessed)
    def serialize_app(app)
      package_name = text(app, :play_package_name)
      return nil if package_name.nil?

      versions = serialize_versions(app)
      body = {
        'metadata' => serialize_metadata(app, versions),
        'versions' => versions
      }
      { package_name: package_name, body: body }
    end

    def serialize_metadata(app, versions)
      metadata = {
        'added' => ms(app_added_at(app)),
        'lastUpdated' => versions.values.map { |v| v['added'] }.compact.max || ms(app_added_at(app)),
        'categories' => categories_for(app),
        'name' => localized(app, :name)
      }
      author = text(app, :publisher_display_name)
      metadata['authorName'] = author if author
      summary = localized(app, :short_description)
      metadata['summary'] = summary if summary
      description = localized(app, :description)
      metadata['description'] = description if description
      icon = icon_for(app)
      metadata['icon'] = { DEFAULT_LOCALE => icon } if icon
      screenshots = screenshots_for(app)
      metadata['screenshots'] = { 'phone' => { DEFAULT_LOCALE => screenshots } } if screenshots.any?
      # Z-P15c: F-Droid's per-package `metadata.preferredSigner` — the certificate its client compares an
      # installed APK's signer against, the same value its signer-index lists. Present on every one of
      # f-droid.org's 4577 packages; omitted here only when no certificate is resolvable at all.
      preferred = signer_fingerprint_for(app)
      metadata['preferredSigner'] = preferred if preferred
      metadata
    end

    # The certificate SHA-256 for this app: the org key's fingerprint when supplied, else the release's own
    # checksum (the fallback the constructor documents). Same read `signer_index_json` uses, per app.
    def signer_fingerprint_for(app)
      @signer_fingerprint || releases_for(app).filter_map { |r| signer_for(r) }.first
    end

    # A locale map for a listing field: the app's own text as en-US, plus any reviewed machine translation
    # (Z-P21) of that field for its locale. nil when there is no text at all.
    def localized(app, member)
      base = text(app, member)
      out = {}
      out[DEFAULT_LOCALE] = base if base
      translations_for(app).each do |locale, fields|
        value = fields[member.to_s]
        out[locale.to_s] = value if value.is_a?(String) && value.present?
      end
      out.empty? ? nil : out
    end

    def categories_for(app)
      return [] unless app.respond_to?(:category)

      category = app.category.to_s.strip
      category.empty? ? [] : [category]
    end

    def icon_for(app)
      release = releases_for(app).find { |r| present?(icon_url(r)) && present?(icon_sha(r)) }
      return nil unless release

      { 'name' => icon_url(release), 'sha256' => icon_sha(release) }
    end

    def screenshots_for(app)
      return [] unless app.respond_to?(:listing_graphics)

      app.listing_graphics.select do |g|
        graphic_kind(g) == 'screenshot' && present?(graphic_url(g)) && present?(graphic_sha(g))
      end.sort_by { |g| [graphic_position(g).to_i, graphic_id(g).to_i] }.map do |g|
        shot = { 'name' => graphic_url(g), 'sha256' => graphic_sha(g) }
        size = graphic_size(g)
        shot['size'] = size if size
        shot
      end
    end

    # versions keyed by the APK's sha256 (F-Droid's own key); the map is insertion-ordered, newest release
    # first, matching the array order the signed index uses.
    def serialize_versions(app)
      releases_for(app).each_with_object({}) do |release, out|
        sha = sha256_for(release)
        next unless present?(sha)
        next if out.key?(sha) # two releases with identical bytes: one version entry, the first (newest) wins

        entry = {
          'added' => ms(release_created_at(release)),
          'file' => file_block(release, sha),
          'manifest' => manifest_block(release)
        }
        out[sha] = entry
      end
    end

    def file_block(release, sha)
      block = { 'name' => download_url(release), 'sha256' => sha }
      size = size_of(release)
      block['size'] = size if size
      block
    end

    def manifest_block(release)
      manifest = {
        'versionName' => text(release, :release_version),
        'versionCode' => version_code(release),
        'usesSdk' => uses_sdk(release)
      }.compact
      signer = signer_for(release)
      manifest['signer'] = { 'sha256' => [signer] } if signer
      nativecode = strings(release, :abis)
      manifest['nativecode'] = nativecode if nativecode.any?
      perms = permission_names(release)
      manifest['usesPermission'] = perms if perms.any?
      manifest
    end

    def uses_sdk(release)
      sdk = {}
      min = int(release, :min_sdk_version)
      target = int(release, :target_sdk_version)
      sdk['minSdkVersion'] = min if min
      sdk['targetSdkVersion'] = target if target
      sdk
    end

    # The releases the signed index would publish (installable, non-held, production track), newest first.
    def releases_for(app)
      list =
        if app.respond_to?(:catalog_releases)
          Array(app.catalog_releases)
        elsif app.respond_to?(:recently_release)
          [app.recently_release].compact
        else
          []
        end
      list.select { |r| installable?(r) }
    end

    # Same rule as CatalogIndex::Serializer#installable_in_index?: a release mid-CI-compile is not offered
    # until its signed universal APK is recorded, or a client would fetch a bundle it cannot install.
    def installable?(release)
      return true unless release.respond_to?(:ci_compile_state) && release.ci_compile_state.present?

      release.respond_to?(:serves_universal_apk?) ? release.serves_universal_apk? : true
    end

    def permission_names(release)
      strings(release, :permissions).reject(&:empty?).uniq.map { |n| { 'name' => n } }
    end

    # ---- duck-typed readers -------------------------------------------------------------------------

    def text(record, member)
      return nil unless record.respond_to?(member)

      value = record.public_send(member)
      value.is_a?(Symbol) ? value.to_s.presence : (value.is_a?(String) ? value.presence : value)
    end

    def int(record, member)
      return nil unless record.respond_to?(member)

      value = record.public_send(member)
      value.nil? ? nil : value.to_i
    end

    def strings(record, member)
      return [] unless record.respond_to?(member)

      Array(record.public_send(member)).map { |v| v.is_a?(Hash) ? nil : v.to_s }.compact
    end

    def version_code(release)
      code = text(release, :build_version)
      code && code.match?(/\A\d+\z/) ? code.to_i : nil
    end

    def download_url(release)
      release.respond_to?(:download_url) ? release.download_url : nil
    end

    def icon_url(release)
      release.respond_to?(:icon_download_url) ? release.icon_download_url : nil
    end

    def icon_sha(release)
      release.respond_to?(:icon_sha256) ? release.icon_sha256 : nil
    end

    # Z-P15c: the certificate fingerprint for a release — the org key's certificate SHA-256 when the caller
    # supplied it (the real F-Droid value), else the release's recorded `signing_key_checksum` (SHA-1 of the
    # keystore — a fallback that is NOT a certificate SHA-256; see the `signer_fingerprint` constructor note).
    def signer_for(release)
      return @signer_fingerprint if @signer_fingerprint
      return nil unless release.respond_to?(:signing_key_checksum)

      release.signing_key_checksum.presence
    end

    def sha256_for(release)
      %i[file_sha256 universal_apk_sha256].each do |member|
        next unless release.respond_to?(member)

        value = release.public_send(member)
        return value if value.present?
      end
      nil
    end

    def size_of(release)
      if release.respond_to?(:size_bytes)
        size = release.public_send(:size_bytes)
        return size.to_i if size.to_i.positive?
      end
      %i[original_size universal_apk_size].each do |member|
        next unless release.respond_to?(member)

        size = release.public_send(member)
        return size.to_i if size.to_i.positive?
      end
      nil
    end

    def graphic_kind(graphic)
      graphic.respond_to?(:kind) ? graphic.kind.to_s : nil
    end

    def graphic_url(graphic)
      graphic.respond_to?(:download_url) ? graphic.download_url : nil
    end

    def graphic_sha(graphic)
      graphic.respond_to?(:sha256) ? graphic.sha256 : nil
    end

    def graphic_size(graphic)
      graphic.respond_to?(:byte_size) ? graphic.byte_size.to_i : nil
    end

    def graphic_position(graphic)
      graphic.respond_to?(:position) ? graphic.position : 0
    end

    def graphic_id(graphic)
      graphic.respond_to?(:id) ? graphic.id : 0
    end

    def translations_for(app)
      MachineTranslation.publishable(app)
    rescue StandardError
      {}
    end

    def app_added_at(app)
      app.respond_to?(:created_at) ? app.created_at : @now
    end

    def release_created_at(release)
      release.respond_to?(:created_at) ? release.created_at : @now
    end

    def ms(value)
      return nil if value.nil?

      time = value.respond_to?(:utc) ? value : Time.parse(value.to_s)
      (time.to_f * 1000).round
    rescue ArgumentError
      nil
    end

    def present?(value)
      value.is_a?(String) ? value.strip.length.positive? : !value.nil?
    end
  end
end
