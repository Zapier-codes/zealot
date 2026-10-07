# frozen_string_literal: true

class UserPolicy < ApplicationPolicy

  def index?
    admin?
  end

  def show?
    admin?
  end

  def create?
    admin?
  end

  def update?
    admin?
  end

  def destroy?
    admin?
  end

  def me?
    user_signed_in?
  end

  def search?
    admin?
  end

  # Task 42j: reading another account's API token over the API: platform admin only, the same power the
  # console's Admin > Users > Edit page already gives.
  def token?
    admin?
  end

  def lock?
    admin?
  end

  def unlock?
    admin?
  end

  def resend_confirmation?
    admin?
  end
  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
