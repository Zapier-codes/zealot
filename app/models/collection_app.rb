# frozen_string_literal: true

# Task 31a: membership of one App in one Collection. A real model (not a
# bare HABTM join) so a future slice can hang per-membership data off it
# (curator's note, position) without another migration.
class CollectionApp < ApplicationRecord
  belongs_to :collection
  belongs_to :app

  validates :app_id, uniqueness: { scope: :collection_id }
  validate :app_and_collection_share_a_tenant

  private

  # Task 37b-iii-s6a: a tenant's index lists an app's collection slugs against that same tenant's
  # collection registry, so a membership may never cross tenants (a default collection cannot hold a
  # tenant's app, nor one tenant's collection another's). Compared by `tenant_id` column, so NULL
  # (default) matches NULL only. Skipped until both sides are set, like the other validations here.
  def app_and_collection_share_a_tenant
    return if app.nil? || collection.nil?
    return if app.tenant_id == collection.tenant_id

    errors.add(:app, :different_tenant)
  end
end
