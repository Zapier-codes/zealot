# frozen_string_literal: true

# Gates Api::MtprotoArchiveController (task 19f): listing archive
# candidates exposes signed download URLs for every eligible release, and
# recording a completion writes to the release, so both need to be
# admin-only, not just any token-holding developer (the ApplicationPolicy
# default of `manage?` would allow that).
#
# Not backed by an ActiveRecord model the way PlayCredentialPolicy is — the
# controller calls `authorize :mtproto_archive, :candidates?, policy_class:
# MtprotoArchivePolicy` explicitly, since Pundit's PolicyFinder can't infer
# a policy class from a bare symbol the way it can from a model instance.
class MtprotoArchivePolicy < ApplicationPolicy
  def candidates?
    admin?
  end

  def complete?
    admin?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
