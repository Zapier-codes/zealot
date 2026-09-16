# frozen_string_literal: true

# Lives entirely under the admin namespace (config/routes.rb wraps
# `namespace :admin` in `authenticate :user, ->(user) { user.admin? }`), so
# every action here is already admin-gated before Pundit runs. This policy
# exists so `authorize` calls in the controller have somewhere to resolve,
# matching AppleKeyPolicy's shape — no extra restrictions beyond the
# ApplicationPolicy defaults (manage?, which is true for any admin).
class AndroidSigningKeyPolicy < ApplicationPolicy

  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
