# frozen_string_literal: true

# Z-P11 (Play Console parity): who may attach or remove a release's mapping / native symbol file, and
# who may read it. It follows the release exactly — the same people who may change a release may upload
# its deobfuscation material, and the same people who may see a release may list what it carries. The
# tenant rule rides on the release's own policy (`in_request_tenant?`): on the default host both are
# `any_manage?`/`show?` as before, on a tenant's host a non-member is refused.
class DebugSymbolPolicy < ApplicationPolicy
  def index?
    release_policy.show?
  end

  def show?
    release_policy.show?
  end

  def create?
    release_policy.update?
  end

  def update?
    release_policy.update?
  end

  def destroy?
    release_policy.update?
  end

  class Scope < Scope
    def resolve
      # A debug symbol is visible exactly when its release is.
      scope.where(release_id: ReleasePolicy::Scope.new(user, Release).resolve.select(:id))
    end
  end

  private

  def release_policy
    @release_policy ||= ReleasePolicy.new(user, record.release)
  end
end
