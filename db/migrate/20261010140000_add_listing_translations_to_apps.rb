# frozen_string_literal: true

# Z-P21 (Play Console parity, docs/PARITY-KANBAN.md): machine translation of listings. One jsonb column
# on `apps` holding the per-locale translations of the listing's free text, keyed by the BCP-47-ish
# locale code ("de", "fr", "zh-CN"):
#
#   { "de" => { "description" => "...", "short_description" => "...",
#               "machine" => true, "reviewed" => false,
#               "source_digest" => "<sha256 of the source text>", "translated_at" => "<iso8601>" } }
#
# A translation is machine-made until a person approves it (`reviewed`), and it records the digest of the
# source text it was made from so an edit to the source marks it stale rather than silently publishing a
# translation of text that no longer exists. Only reviewed, non-stale translations reach the catalog index.
class AddListingTranslationsToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :listing_translations, :jsonb, null: false, default: {}
  end
end
