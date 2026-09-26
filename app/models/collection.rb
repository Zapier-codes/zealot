# frozen_string_literal: true

# Task 31a: a named, described grouping of apps -- the Zealot-side registry
# the v2 catalog index's per-app `collections[]` field (reserved since
# 29a/29b) resolves against. Published as a new top-level `collections[]`
# array in the index (see CatalogIndex::Serializer#serialize_collections),
# distinct from an app's own membership list.
#
# `slug` is the stable identifier both the index and D-store's own
# `Collection` type (`4.c.ii.zo`) key off of -- immutable in spirit (not
# enforced here yet; nothing generates or freezes one automatically the way
# Task 30's App#slug eventually will), so changing it after publish should
# be treated as renaming, not just editing.
class Collection < ApplicationRecord
  SLUG_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  has_many :collection_apps, dependent: :destroy
  has_many :apps, through: :collection_apps

  before_validation :normalize_slug

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :name, presence: true

  scope :ordered, -> { order(:slug) }

  private

  def normalize_slug
    self.slug = slug.to_s.strip.downcase.gsub(/\s+/, '-') if slug.present?
  end
end
