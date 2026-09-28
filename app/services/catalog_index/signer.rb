# frozen_string_literal: true

require 'json'
require 'time'

module CatalogIndex
  # Task 27b-ii: builds the catalog index and signs it.
  #
  # The output is exactly two things to publish (27b-iii does the publishing):
  #   index.json      the bytes in Result#index_json — never re-serialised
  #   index.json.sig  Result#signature, base64 Ed25519 over those exact bytes
  # plus the public key (CatalogIndexSigningKey#public_key), published once.
  #
  # Rollback protection: the index's own `generated_at` is the strictly
  # increasing counter. It is never earlier than, or equal to, the previous
  # signed one — even if the server clock goes backwards — so a reader that
  # remembers the newest `generated_at` it has accepted can reject any older
  # or replayed index. The previous value is persisted on the key row and read
  # and advanced under a row lock, so two concurrent signings can't hand out
  # the same timestamp. (Second resolution, because that is what the v1 schema
  # carries.)
  #
  # Task 37b-ii-k4/k5: the key is chosen by `CatalogIndex::KeyResolver` (default: the tenant's
  # key; no tenant means the default tenant, so today's callers are unchanged). During a key
  # rotation a tenant has TWO valid keys (`active` + `retiring`); every one of them signs the
  # SAME bytes. `Result#signature`/`key_id` stay the primary's (the `active` key, the first one),
  # `Result#signatures` lists all of them. The counter is the maximum across the keys, plus one
  # second if needed, and every key is advanced to it, so no key's counter (and so no reader's
  # anti-rollback memory) ever goes backwards. Key rows are locked in ascending id order, the same
  # order `TenantKeys::Lifecycle` uses for them, so the two cannot deadlock.
  class Signer
    class NoKeyError < StandardError; end

    Result = Struct.new(:index_json, :signature, :key_id, :generated_at, :signatures, keyword_init: true)

    # The next `generated_at`: now, but at least one second after the last
    # one signed.
    def self.next_generated_at(now, last_signed_at)
      candidate = Time.at(now.to_i).utc
      return candidate if last_signed_at.nil?

      [candidate, Time.at(last_signed_at.to_i).utc + 1].max
    end

    # Only live, non-archived apps belong in a public catalog. Task 37b-iii-s3: and only the
    # DEFAULT tenant's (`tenant_id IS NULL`), so an app a tenant owns can never show up in the
    # default catalog. Identical to before for every existing app, all of which have no tenant.
    def self.default_apps
      apps_for(nil)
    end

    # Task 37b-iii-s4: the same rule for any tenant: live, non-archived, and only that tenant's own
    # apps. Task 38c: plus every descendant tenant's (`App.for_tenant_subtree`); the default tenant
    # never cascades. An unknown tenant gets none, never the default catalog.
    def self.apps_for(tenant)
      App.listing_live.for_tenant_subtree(tenant).where(archived: [false, nil])
    end

    # `key:` is one key or an array of keys, primary first. It defaults to every key valid for
    # `tenant` right now (see the class comment); pass `key:` to override, as before.
    #
    # With no `apps`, the list is `apps_for(tenant)`: that tenant's own live apps (Task 37b-iii-s4
    # lifted the k4 guard that made a non-default tenant pass them explicitly, now that
    # `App.for_tenant` exists). Task 37b-iii-s6a: a non-default tenant's index carries its own
    # collections and, since s6b, its own apps' sponsored slots (see `Serializer.call`).
    def self.call(apps = nil, now: Time.now.utc, tenant: nil, key: CatalogIndex::KeyResolver.signing_keys_for(tenant))
      new(apps, now: now, key: key, tenant: tenant).call
    end

    def initialize(apps, now:, key:, tenant: nil)
      @apps = apps
      @tenant = tenant
      @now = now
      @keys = key.is_a?(Array) ? key.compact : [key].compact
    end

    def call
      raise NoKeyError, 'no catalog-index signing key; run `rake catalog_index:generate_key`' if @keys.empty?

      with_locks(@keys.sort_by(&:id)) do
        generated_at = self.class.next_generated_at(@now, @keys.filter_map(&:last_signed_at).max)
        index = CatalogIndex::Serializer.call(@apps || self.class.apps_for(@tenant), generated_at: generated_at,
                                              tenant: @tenant)
        json = "#{JSON.pretty_generate(index)}\n"
        signatures = @keys.map { |k| { key_id: k.key_id, signature: k.sign(json) } }
        @keys.each { |k| k.update!(last_signed_at: generated_at) }

        Result.new(index_json: json, signature: signatures.first[:signature], key_id: signatures.first[:key_id],
                   generated_at: generated_at, signatures: signatures)
      end
    end

    private

    # Nested `with_lock`s, outermost first, so the rows are locked in the order given. Each one
    # is its own transaction level, and all of them commit or roll back together.
    def with_locks(keys, &block)
      return yield if keys.empty?

      keys.first.with_lock { with_locks(keys.drop(1), &block) }
    end
  end
end
