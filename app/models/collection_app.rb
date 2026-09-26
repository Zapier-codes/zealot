# frozen_string_literal: true

# Task 31a: membership of one App in one Collection. A real model (not a
# bare HABTM join) so a future slice can hang per-membership data off it
# (curator's note, position) without another migration.
class CollectionApp < ApplicationRecord
  belongs_to :collection
  belongs_to :app

  validates :app_id, uniqueness: { scope: :collection_id }
end
