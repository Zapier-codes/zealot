# frozen_string_literal: true

# Z-P18 (audit-log slice; Play Console parity, docs/PLAY-PARITY.md): the audit log list. Read-only: the log is written by
# the code that makes each change (`AuditEntry.record`), never edited from the console.
#
# Optional filters, applied to the tenant-scoped relation:
#   subject_type  e.g. ?subject_type=AndroidSigningKey
#   entry_action  created / updated / destroyed  (not `action`, which is the controller action)
#   q             a free-text match against the frozen `summary`
class Admin::AuditEntriesController < ApplicationController
  PER_PAGE = 50

  def index
    authorize AuditEntry
    @title = t('admin.audit_entries.index.title')

    relation = policy_scope(AuditEntry).recent
    relation = relation.where(subject_type: params[:subject_type]) if params[:subject_type].present?
    relation = relation.where(action: params[:entry_action]) if params[:entry_action].present?
    if params[:q].present?
      relation = relation.where('summary ILIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s)}%")
    end

    @audit_entries = relation.page(params[:page]).per(PER_PAGE)
    @subject_types = AuditEntry.distinct.order(:subject_type).pluck(:subject_type)
  end
end
