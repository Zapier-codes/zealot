# frozen_string_literal: true

# Same shape as AndroidSigningKeyPolicy — admin-only namespace already
# gates access at the routing level (config/routes.rb), this just gives
# `authorize` calls somewhere to resolve.
class PlayUploadKeyPolicy < ApplicationPolicy

  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
