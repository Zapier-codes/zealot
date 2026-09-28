# frozen_string_literal: true

# Task 37b-ii-t3. The admin namespace is already gated at the routing level, but a tenant
# decides which hosts serve which site, so admin-only is stated here too rather than relying on
# ApplicationPolicy's `manage?` (true for any developer). No destroy: see the controller.
class TenantPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def new?
    admin?
  end

  def create?
    admin?
  end

  def edit?
    admin?
  end

  def update?
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
