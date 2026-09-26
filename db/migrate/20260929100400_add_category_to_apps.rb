# frozen_string_literal: true

# Resolves catalog_index_v2.md's open ❓1 ("Category vocabulary: fixed list
# vs. Zealot-owned free text"): the operator chose full Play-parity — the
# same category (and, for games, sub-category) vocabulary Play Console
# itself offers, not the smaller 12-item placeholder list the v2 doc
# originally matched against D-store's own categories. See
# App::APP_CATEGORIES / App::GAME_CATEGORIES for the vocabulary itself and
# CatalogIndex::Serializer::CATEGORIES, which now reads from it instead of
# carrying a second hand-copied list.
#
# Nullable, no default: an app with no category set is exactly Play
# Console's own "no uncategorized option, but nothing forces you to pick
# one at draft time" state until the owner actually chooses one -- same
# "reserved, not invented" spirit as every other still-nil listing field
# CatalogIndex::Serializer documents.
class AddCategoryToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :category, :string
  end
end
