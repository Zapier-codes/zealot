# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (audit-log slice): the read-only audit list. A platform admin sees it; a non-admin does not.
# Written-not-run in the sandbox (no bundle); the model's own behaviour is in audit_entry_spec.rb.
RSpec.describe 'Admin audit log', type: :request do
  let(:password) { 'correct-horse-9' }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  let!(:admin) { make_user('admin@example.com', :admin) }

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: password } }
  end

  before do
    Zealot::TenantRegistry.reset!
    AuditEntry.record(action: 'created', subject: ['AndroidSigningKey', 1], actor: admin,
                      summary: 'android_signing_key created checksum=ab12')
  end

  it 'shows the log to an admin' do
    sign_in(admin)
    get admin_audit_entries_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('android_signing_key created checksum=ab12')
  end

  it 'refuses a non-admin' do
    sign_in(make_user('dev@example.com', :developer))
    get admin_audit_entries_path

    expect(response).not_to have_http_status(:ok)
  end

  it 'filters by subject type' do
    sign_in(admin)
    get admin_audit_entries_path, params: { subject_type: 'App' }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('android_signing_key created checksum=ab12')
  end
end
