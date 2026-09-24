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

    Result = Struct.new(:status, :commit_sha, :generated_at, :key_id, :hook, keyword_init: true)

    def self.configured?
      CatalogIndex::GithubPagesCommit.configured? && !CatalogIndexSigningKey.current.nil?
    end

    def self.call(**opts)
      new(**opts).call
    end

    def initialize(apps: nil, client: nil, key: CatalogIndexSigningKey.current, now: Time.now.utc,
                   hook_url: ENV['DSTORE_DEPLOY_HOOK_URL'], hook_transport: nil, logger: Rails.logger)
      @apps = apps
      @client = client
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
      signed = CatalogIndex::Signer.call(@apps, now: @now, key: @key)
      files = {
        'index.json' => signed.index_json,
        'index.json.sig' => "#{signed.signature}\n",
        'signing_key.pub' => "#{@key.public_key}\n",
        '.nojekyll' => ''
      }
      commit = client.publish(files, message: "catalog index #{signed.generated_at.utc.iso8601} (#{signed.key_id})")

      Result.new(status: commit.status, commit_sha: commit.commit_sha,
                 generated_at: signed.generated_at, key_id: signed.key_id)
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
