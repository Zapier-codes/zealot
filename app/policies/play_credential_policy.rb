# frozen_string_literal: true

# Same shape as AndroidSigningKeyPolicy/PlayUploadKeyPolicy.
class PlayCredentialPolicy < ApplicationPolicy

  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
