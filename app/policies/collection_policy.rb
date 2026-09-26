# frozen_string_literal: true

# Same shape as PlayUploadKeyPolicy -- Admin::CollectionsController already
# lives behind the admin-only namespace at the routing level; this exists so
# `authorize` calls have somewhere to resolve, and so a future non-admin
# surface (there isn't one today) inherits the same manage?-gated defaults.
class CollectionPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
