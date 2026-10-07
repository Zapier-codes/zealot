# frozen_string_literal: true

require 'digest'

module CatalogIndex
  # Task 27b-iii: sign the current catalog and publish it to the Pages repo,
  # then tell D-store to redeploy.
  #
  # Serialized: the whole sign -> commit sequence runs under one Postgres
  # advisory lock, so two publishes can never interleave and the order they
  # are signed in is the order they land in (otherwise an older index could
  # overwrite a newer one, and readers would be left looking at stale state).
  # The lock belongs to the DB session, so it also serializes separate
  # processes and is released automatically if a process dies.
  #
  # Published as ONE commit: index.json, index.json.sig, signing_key.pub
  # (base64 raw Ed25519 key, so a reader can always find the key that goes with
  # the signature), and an empty .nojekyll (so Pages serves the files as-is).
  #
  # The deploy hook (DSTORE_DEPLOY_HOOK_URL, optional) is fired only after a
  # commit actually landed, and never fails the publish: the index is already
  # public by then, and D-store also refreshes on its own cache rule. The hook
  # URL is a secret and is never logged.
  class Publish
    LOCK_KEY = 2_027_003 # arbitrary, fixed: "task 27b-iii"

    # Task 37b-ii-k4 added this guard because `Publish` wrote the four FIXED root paths, so a
    # non-default tenant's index would have overwritten the default tenant's files. Task 37b-iii-s4
    # lifted it (each tenant now has its own root, lock and app list), but the class stays so
    # anything still rescuing it keeps loading; nothing raises it any more.
    class TenantNotScopedError < StandardError; end

    Result = Struct.new(:status, :commit_sha, :generated_at, :key_id, :hook, keyword_init: true)

    # Task 37b-iii-s1: the advisory-lock statement for one tenant. The DEFAULT tenant keeps the
    # exact single-key statement it has always used. Any other tenant takes the two-key form
    # `(LOCK_KEY, hashtext(tenant_id))`, which Postgres keeps in a separate key space from the
    # single-key form, so a tenant can never contend with the default tenant's lock, and two
    # tenants only share a lock on a `hashtext` collision (harmless: they just take turns).
    # `verb` is `lock` or `unlock`; the tenant id is quoted by the connection, never interpolated.
    def self.lock_sql(connection, tenant, verb)
      raise ArgumentError, "verb must be lock or unlock, got #{verb.inspect}" unless %w[lock unlock].include?(verb)
      return "SELECT pg_advisory_#{verb}(#{LOCK_KEY})" if CatalogIndex::KeyResolver.default?(tenant)

      id = CatalogIndex::KeyResolver.tenant_id_of(tenant)
      "SELECT pg_advisory_#{verb}(#{LOCK_KEY}, hashtext(#{connection.quote(id)}))"
    end

    # Task 37b-iii-s5: `tenant` defaults to the default tenant, whose answer is unchanged. Another
    # tenant is configured when the Pages repo is AND that tenant has an active signing key
    # (`KeyResolver` raises `NoKeyError` for an unknown tenant or a keyless one; that is "no").
    def self.configured?(tenant = nil)
      return false unless CatalogIndex::GithubPagesCommit.configured?
      return !CatalogIndexSigningKey.current.nil? if CatalogIndex::KeyResolver.default?(tenant)

      !CatalogIndex::KeyResolver.for(tenant).nil?
    rescue CatalogIndex::KeyResolver::NoKeyError
      false
    end

    def self.call(**opts)
      new(**opts).call
    end

    def initialize(apps: nil, client: nil, tenant: nil, key: CatalogIndex::KeyResolver.for(tenant), now: Time.now.utc,
                   hook_url: ENV['DSTORE_DEPLOY_HOOK_URL'], hook_transport: nil, logger: Rails.logger)
      @apps = apps
      @client = client
      @tenant = tenant
      @key = key
      @now = now
      @hook_url = hook_url.to_s.strip
      @hook_transport = hook_transport
      @logger = logger
    end

    def call
      raise CatalogIndex::Signer::NoKeyError, 'no catalog-index signing key; run `rake catalog_index:generate_key`' if @key.nil?

      client = @client || CatalogIndex::GithubPagesCommit.new
      result = with_publish_lock { sign_and_commit(client) }
      result.hook = fire_hook if result.status == :published
      result
    end

    private

    def sign_and_commit(client)
      signed = CatalogIndex::Signer.call(@apps, now: @now, tenant: @tenant, key: @key)
      files = {
        'index.json' => signed.index_json,
        'index.json.sig' => "#{signed.signature}\n",
        'signing_key.pub' => "#{@key.public_key}\n",
        '.nojekyll' => ''
      }
      commit = client.publish(files, message: "catalog index#{message_scope} #{signed.generated_at.utc.iso8601} (#{signed.key_id})",
                                     root: publish_root)

      store_snapshot(signed)
      Result.new(status: commit.status, commit_sha: commit.commit_sha,
                 generated_at: signed.generated_at, key_id: signed.key_id)
    end

    # Task 45g: keep the exact signed bytes so CatalogController can serve them from this host. The Pages commit
    # has already landed, so a failure here is logged and never fails (or retries) the publish; the host then
    # keeps serving the previous, still validly signed, copy until the next publish.
    def store_snapshot(signed)
      CatalogIndexSnapshot.store!(tenant: @tenant, index_json: signed.index_json, signature: "#{signed.signature}\n",
                                  signing_key_id: signed.key_id, generated_at: signed.generated_at)
    rescue StandardError => e
      @logger&.error("[CatalogIndex::Publish] could not store the index snapshot: #{e.class}: #{e.message}")
    end

    # nil (the repo root, exactly as before) for the default tenant, `tenants/<id>` for any other.
    def publish_root
      return nil if CatalogIndex::KeyResolver.default?(@tenant)

      CatalogIndex::GithubPagesCommit.root_for(CatalogIndex::KeyResolver.tenant_id_of(@tenant))
    end

    # The default tenant's commit message is unchanged; another tenant's names it.
    def message_scope
      CatalogIndex::KeyResolver.default?(@tenant) ? '' : " [#{CatalogIndex::KeyResolver.tenant_id_of(@tenant)}]"
    end

    def with_publish_lock
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute(self.class.lock_sql(connection, @tenant, 'lock'))
        begin
          yield
        ensure
          connection.execute(self.class.lock_sql(connection, @tenant, 'unlock'))
        end
      end
    end

    # :skipped (not configured), :sent, or :failed. Never raises.
    def fire_hook
      return :skipped if @hook_url.empty?

      transport = @hook_transport || ReleaseStorage::GithubAdapter::HttpTransport.new
      response = transport.call(:post, @hook_url, headers: { 'User-Agent' => 'zealot-catalog-index' }, body: '')
      return :sent if response.status.between?(200, 299)

      @logger&.warn("[CatalogIndex::Publish] D-store deploy hook answered HTTP #{response.status}")
      :failed
    rescue StandardError => e
      @logger&.warn("[CatalogIndex::Publish] D-store deploy hook failed: #{e.class}")
      :failed
    end
  end
end
