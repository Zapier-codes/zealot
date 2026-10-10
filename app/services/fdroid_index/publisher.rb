# frozen_string_literal: true

module FdroidIndex
  # Z-P15b (Play Console parity; docs/PARITY-KANBAN.md): sign Z-P15a's `entry.json` into `entry.jar`
  # and publish the F-Droid repo directory beside the signed Zealot index, so an F-Droid-style client
  # (F-Droid, Droid-ify, Neo Store, Obtainium) can read our apps. The Zealot index stays the trust
  # anchor; this is an additional view (docs/UNOFFICIAL-ROUTES.md).
  #
  # ## What is published, and where
  # Three files, as ONE commit, at the Pages repo root (the default tenant owns the root; a tenant
  # publishes under `tenants/<id>`, see CatalogIndex::GithubPagesCommit#root_for):
  #   * `index-v2.json`  -- Z-P15a's catalog, unchanged
  #   * `entry.json`     -- Z-P15a's entry point, unchanged
  #   * `entry.jar`      -- entry.json inside a JAR signed with the org signing key (this slice)
  # The JAR is published as a **binary** blob (base64 through the Git Data API): it is not UTF-8.
  #
  # ## Off by default, and why it is a separate switch
  # `ENABLE_FDROID_INDEX` gates this (default false). It is separate from the Zealot index publish so a
  # deployment can serve the Zealot index to Storeapp/D-Store without also serving an F-Droid repo; the
  # only shared prerequisite is a configured Pages repo and the org signing key (AndroidSigningKey).
  # A missing key or a disabled flag is logged and skipped, never raised, so the normal publish path is
  # never broken by this (the same posture as CatalogIndexPublishJob).
  #
  # ## The one assumption this cannot confirm here
  # The serializer publishes each APK's `file.name` as an **absolute** Zealot download URL, so the APK
  # is never mirrored into the Pages repo. F-Droid's own index uses a repo-relative path; a client
  # resolves `file.name` against the repo `address`, and an absolute URL wins that resolution. That an
  # F-Droid client honours an absolute `file.name` is read from the client's `FileV2`/`Downloader`
  # sources but **not run against a real client from this sandbox**; it stays flagged on the kanban card.
  # `manifest.signer` is published from the release's `signing_key_checksum` (the same SHA-1-of-keystore
  # value the Zealot index publishes as `signing_fingerprint`), not a certificate SHA-256; `preferredSigner`
  # is therefore left out until that value is reconciled with what F-Droid expects.
  class Publisher
    LOCK_KEY = 2_027_015 # arbitrary, fixed: "Z-P15b" (distinct from CatalogIndex::Publish::LOCK_KEY)

    class ConfigurationError < StandardError; end
    class NoKeyError < StandardError; end

    Result = Struct.new(:status, :commit_sha, :generated_at, :package_count, :key_id, keyword_init: true)

    # Enabled AND the Pages repo is configured AND the org signing key exists.
    def self.configured?(env = ENV)
      return false unless env.fetch('ENABLE_FDROID_INDEX', 'false').to_s.downcase == 'true'
      return false unless CatalogIndex::GithubPagesCommit.configured?(env)

      AndroidSigningKey.current.present?
    end

    def self.call(**opts)
      new(**opts).call
    end

    def initialize(apps: nil, client: nil, repo_name: 'Zealot', repo_description: nil,
                   repo_address: ENV['FDROID_REPO_ADDRESS'], now: Time.now.utc, logger: Rails.logger)
      @apps = apps
      @client = client
      @repo_name = repo_name
      @repo_description = repo_description
      @repo_address = repo_address
      @now = now
      @logger = logger
    end

    def call
      raise ConfigurationError, 'FDROID_REPO_ADDRESS is not set (the URL a client fetches the repo from)' if @repo_address.to_s.strip.empty?

      key = AndroidSigningKey.current
      raise NoKeyError, 'no AndroidSigningKey configured; cannot sign entry.jar' if key.nil?

      serializer_result = FdroidIndex::Serializer.call(
        @apps || CatalogIndex::Signer.default_apps,
        now: @now,
        repo_name: @repo_name,
        repo_description: @repo_description,
        repo_address: @repo_address
      )
      jar_bytes = FdroidIndex::JarSigner.new(
        entry_json: serializer_result.entry_json, index_json: serializer_result.index_json
      ).call
      signed_jar = FdroidIndex::JarSigner.sign_jar!(
        jar_bytes,
        keystore_bytes: key.keystore,
        keystore_password: key.keystore_password,
        key_alias: key.key_alias,
        key_password: key.key_password
      )
      commit = publish(serializer_result, signed_jar)
      Result.new(status: commit.status, commit_sha: commit.commit_sha, generated_at: serializer_result.generated_at,
                 package_count: serializer_result.package_count)
    end

    private

    def publish(result, signed_jar)
      client = @client || CatalogIndex::GithubPagesCommit.new
      files = {
        'index-v2.json' => result.index_json,
        'entry.json' => result.entry_json,
        'entry.jar' => signed_jar
      }
      with_publish_lock do
        client.publish(
          files,
          message: "fdroid index #{result.generated_at.utc.iso8601} (#{result.package_count} packages)",
          root: publish_root,
          binary: ['entry.jar']
        )
      end
    end

    # nil (the repo root, the default tenant) for now; F-Droid publishing is default-tenant only until a
    # tenant's own repo address/key is carded, so this mirrors CatalogIndex::Publish's default-tenant path.
    def publish_root
      nil
    end

    def with_publish_lock
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SELECT pg_advisory_lock(#{LOCK_KEY})")
        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})")
        end
      end
    end
  end
end
