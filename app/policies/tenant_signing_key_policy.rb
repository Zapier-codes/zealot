# frozen_string_literal: true

# Task 37b-ii-k6. The four lifecycle steps for a tenant's signing key (generate the first key,
# stage the next, promote, retire) are admin-only. The admin namespace is already gated at the
# routing level, but this is secret-handling surface, so admin-only is stated here too rather than
# relying on ApplicationPolicy's `manage?` (true for any developer). There is no destroy: a key
# leaves the system by being retired, which destroys its private half, never by deleting the row.
class TenantSigningKeyPolicy < ApplicationPolicy
  def generate?
    admin?
  end

  def stage_next?
    admin?
  end

  def promote?
    admin?
  end

  def retire?
    admin?
  end

  def destroy?
    false
  end

  class Scope < Scope
    def resolve
      admin? ? scope.all : scope.none
    end
  end
end
