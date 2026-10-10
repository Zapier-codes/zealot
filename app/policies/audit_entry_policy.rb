# frozen_string_literal: true

# Z-P18 (audit-log slice): the audit log is read-only in the console and only for a platform admin. `index?` is the only
# action; there is no create/update/destroy through the web (the log is written by the code that makes
# the change). `tenant_access?` from the base policy keeps a tenant admin on a tenant's host to that
# tenant's entries (the Scope resolves with `for_tenant`).
class AuditEntryPolicy < ApplicationPolicy
  def index?
    tenant_access? && user_signed_in_or_guest_mode? && admin?
  end
end
