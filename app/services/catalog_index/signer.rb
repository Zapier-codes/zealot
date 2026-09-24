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
  class Signer
    class NoKeyError < StandardError; end

    Result = Struct.new(:index_json, :signature, :key_id, :generated_at, keyword_init: true)

    # The next `generated_at`: now, but at least one second after the last
    # one signed.
    def self.next_generated_at(now, last_signed_at)
      candidate = Time.at(now.to_i).utc
      return candidate if last_signed_at.nil?

      [candidate, Time.at(last_signed_at.to_i).utc + 1].max
    end

    # Only live, non-archived apps belong in a public catalog.
    def self.default_apps
      App.listing_live.where(archived: [false, nil])
    end

    def self.call(apps = nil, now: Time.now.utc, key: CatalogIndexSigningKey.current)
      new(apps, now: now, key: key).call
    end

    def initialize(apps, now:, key:)
      @apps = apps
      @now = now
      @key = key
    end

    def call
      raise NoKeyError, 'no catalog-index signing key; run `rake catalog_index:generate_key`' if @key.nil?

      @key.with_lock do
        generated_at = self.class.next_generated_at(@now, @key.last_signed_at)
        index = CatalogIndex::Serializer.call(@apps || self.class.default_apps, generated_at: generated_at)
        json = "#{JSON.pretty_generate(index)}\n"
        signature = @key.sign(json)
        @key.update!(last_signed_at: generated_at)

        Result.new(index_json: json, signature: signature, key_id: @key.key_id, generated_at: generated_at)
      end
    end
  end
end
