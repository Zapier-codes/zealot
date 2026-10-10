# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (audit-log slice): the audit log's behaviour that matters — append-only entries, the tenant scope (deny by
# default), and the guarantee that a secret never lands in `metadata`.
RSpec.describe AuditEntry, type: :model do
  let(:user) { create(:user) }

  describe '.record' do
    it 'writes one entry naming the actor, the action and the subject' do
      app = create(:app)
      entry = described_class.record(action: 'updated', subject: app, actor: user, summary: 'changed')

      expect(entry).to be_persisted
      expect(entry.action).to eq('updated')
      expect(entry.subject_type).to eq('App')
      expect(entry.subject_id).to eq(app.id)
      expect(entry.actor).to eq(user)
    end

    it 'accepts a plain [type, id] pair for a subject that is already gone' do
      entry = described_class.record(action: 'destroyed', subject: ['AndroidSigningKey', 42], actor: user)

      expect(entry.subject_type).to eq('AndroidSigningKey')
      expect(entry.subject_id).to eq(42)
    end

    it 'never records a secret in metadata' do
      entry = described_class.record(
        action: 'created',
        subject: ['AndroidSigningKey', 1],
        actor: user,
        metadata: { kind: 'created', keystore_password: 'hunter2', nested: { token: 'zpa_secret', ok: true } }
      )

      expect(entry.metadata).to eq('kind' => 'created', 'nested' => { 'ok' => true })
      expect(entry.metadata.to_s).not_to include('hunter2', 'zpa_secret')
    end

    it 'is not written for a blank subject and does not raise' do
      expect(described_class.record(action: 'created', subject: nil, actor: user)).to be_nil
    end

    it 'rejects an action outside the known set' do
      entry = described_class.record(action: 'sideways', subject: ['App', 1], actor: user)

      expect(entry).to be_nil
      expect(described_class.where(action: 'sideways')).not_to exist
    end
  end

  describe 'tenant scope' do
    let(:tenant) { create(:tenant) }

    it 'lists only a tenant\'s own entries on that tenant\'s host' do
      mine = described_class.record(action: 'updated', subject: ['App', 1], tenant: tenant, summary: 'mine')
      described_class.record(action: 'updated', subject: ['App', 2], summary: 'theirs')

      expect(described_class.for_tenant(tenant)).to include(mine)
      expect(described_class.for_tenant(tenant).pluck(:summary)).to eq(['mine'])
    end

    it 'lists the whole platform log on the default host (tenant nil)' do
      described_class.record(action: 'updated', subject: ['App', 1], summary: 'a')
      described_class.record(action: 'updated', subject: ['App', 2], tenant: tenant, summary: 'b')

      expect(described_class.for_tenant(nil).count).to eq(1)
    end
  end

  describe '#description' do
    it 'prefers the frozen summary, so the entry stays readable after the subject changes name' do
      entry = described_class.record(action: 'updated', subject: ['App', 1], summary: 'android_signing_key created checksum=ab12')

      expect(entry.description).to eq('android_signing_key created checksum=ab12')
    end

    it 'falls back to the i18n key when no summary was frozen' do
      entry = described_class.new(action: 'updated', subject_type: 'App', summary_i18n_key: 'admin.audit_entries.summary.app_api_token')

      expect(entry.description).to eq(I18n.t('admin.audit_entries.summary.app_api_token'))
    end
  end
end
