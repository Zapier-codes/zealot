# frozen_string_literal: true

# Same shape as CollectionPolicy/PlayUploadKeyPolicy -- admin-only namespace
# already gates access at the routing level, this just gives `authorize`
# calls somewhere to resolve.
class SponsoredSlotPolicy < ApplicationPolicy
  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
