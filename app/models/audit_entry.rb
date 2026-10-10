# frozen_string_literal: true

# Z-P18 (audit-log slice; Play Console parity, docs/PLAY-PARITY.md): the Console's audit log.
#
# Play Console keeps a "Changes log" / "Audit log" of who changed what and when. Zealot had none: the
# two places that wanted one wrote a `Rails.logger.info` line with a "stand-in until the audit log of
# Task 34c exists" comment. This model is that log. It is append-only — the app never updates or
# deletes a row — and it is written from the places that make a change, one `AuditEntry.record` call
# each.
#
# An entry names the actor (`actor`), the tenant the change belongs to (`tenant_id`, so a console
# admin on a tenant's host only sees that tenant's entries — the same deny-by-default rule the other
# tenant-scoped models follow), the thing changed (`subject` via a polymorphic `subject_type`/
# `subject_id` that never constrains the actor to a live row, so a removed key's history survives it)
# and a small `metadata` blob (ids, last-four, counts — NEVER a secret; see `FORBIDDEN_KEYS`).
#
# `summary_i18n_key` + `summary` is the whole point: the list is rendered from values frozen into the
# row at the time of the change, so the entry stays readable even after the thing it names is gone or
# its name changed. That is the property an audit log is for.
class AuditEntry < ApplicationRecord
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :tenant, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  # Keys a caller must never put in `metadata`. `record` drops them (rather than raising) so a caller can
  # pass a whole params hash and the attribution keeps working; what is dropped is stated in the row.
  FORBIDDEN_KEYS = %w[
    password password_confirmation encrypted_password token reset_password_token
    unlock_token confirmation_token keystore_password key_password private_key
    secret api_key authorization
  ].freeze

  ACTIONS = %w[created updated destroyed].freeze

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :subject_type, presence: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  # Deny by default on a tenant's host: a tenant sees only its own entries; the default host (row tenant
  # nil) sees the platform-wide log. Mirrors ApplicationPolicy::Scope#resolve.
  scope :for_tenant, ->(tenant) { where(tenant_id: tenant&.id) }

  # Append one entry. `subject` may be a live record or a plain `[type, id]` pair (a row already gone);
  # `actor` and `tenant` default to the request context. Returns the entry, or nil when the log could
  # not be written — a failed audit write must never break the change it is describing.
  def self.record(action:, subject:, actor: nil, tenant: nil, summary_i18n_key: nil, summary: nil,
                  metadata: {}, at: Time.current)
    subject_type, subject_id = subject_ref(subject)
    return nil if subject_type.blank?

    create!(
      action: action.to_s,
      subject_type: subject_type,
      subject_id: subject_id,
      actor: actor,
      tenant: tenant,
      summary_i18n_key: summary_i18n_key,
      summary: summary,
      metadata: sanitize_metadata(metadata),
      created_at: at,
      updated_at: at
    )
  rescue StandardError => e
    Rails.logger.warn("[AuditEntry] could not record #{action} #{subject_type}: #{e.class}: #{e.message}")
    nil
  end

  def self.subject_ref(subject)
    return [subject[0], subject[1]] if subject.is_a?(Array) && subject.size == 2
    return [nil, nil] if subject.nil?

    [subject.class.polymorphic_name, subject.id]
  end

  # Drop the forbidden keys, recursively, and stringify keys so the jsonb column is predictable.
  def self.sanitize_metadata(value)
    case value
    when Hash
      value.each_with_object({}) do |(k, v), out|
        key = k.to_s
        next if FORBIDDEN_KEYS.include?(key)

        out[key] = sanitize_metadata(v)
      end
    when Array
      value.map { |v| sanitize_metadata(v) }
    else
      value
    end
  end

  # The human line for the list. The frozen `summary` is preferred: it carries the concrete facts
  # (ids, last-four, checksums) exactly as they were at the time of the change, which is the property
  # an audit log needs — it stays readable after the thing it names is gone. `summary_i18n_key` is the
  # fallback for a caller that stored only a key (and, where a locale adds it, the translated line).
  def description
    return summary if summary.present?
    return I18n.t(summary_i18n_key) if summary_i18n_key.present?

    "#{action} #{subject_type}"
  end

  # For the two admin surfaces that were stand-ins: the audit writes were `[kind] ...` log lines. This
  # turns the stored `metadata['kind']` back into the same short token they used.
  def kind
    metadata.is_a?(Hash) ? metadata['kind'] : nil
  end
end
