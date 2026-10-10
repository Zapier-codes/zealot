# frozen_string_literal: true

require 'rails_helper'

# Z-P19: the Standard Webhooks signature pair (sign then verify). Written, NOT run in the sandbox that wrote
# it (no bundle there). Pure Ruby — no doubles needed.
RSpec.describe Webhooks::StandardSignature do
  let(:secret) { 'whsec_' + Base64.strict_encode64('a-shared-signing-key-0123456789') }
  let(:id) { 'msg_2b0Zf9' }
  let(:body) { '{"event":"upload_events","name":"Example App"}' }
  let(:now) { Time.zone.parse('2026-10-10 12:00:00') }

  it 'signs and verifies a fresh delivery' do
    timestamp = now.to_i
    header = described_class.header(secret: secret, webhook_id: id, timestamp: timestamp, body: body)

    expect(header).to start_with('v1,')
    expect(described_class.valid?(secret: secret, webhook_id: id, timestamp: timestamp, body: body,
                               signature: header, now: now)).to be(true)
  end

  it 'refuses a body that was altered after signing' do
    timestamp = now.to_i
    header = described_class.header(secret: secret, webhook_id: id, timestamp: timestamp, body: body)

    expect(described_class.valid?(secret: secret, webhook_id: id, timestamp: timestamp,
                               body: body + ' ', signature: header, now: now)).to be(false)
  end

  it 'refuses a signature made with a different secret' do
    timestamp = now.to_i
    other = 'whsec_' + Base64.strict_encode64('a-different-key')
    header = described_class.header(secret: other, webhook_id: id, timestamp: timestamp, body: body)

    expect(described_class.valid?(secret: secret, webhook_id: id, timestamp: timestamp, body: body,
                               signature: header, now: now)).to be(false)
  end

  it 'refuses a stale delivery outside the tolerance window' do
    timestamp = (now - (6 * 60)).to_i
    header = described_class.header(secret: secret, webhook_id: id, timestamp: timestamp, body: body)

    expect(described_class.valid?(secret: secret, webhook_id: id, timestamp: timestamp, body: body,
                               signature: header, now: now)).to be(false)
  end

  it 'returns nil (unsigned) when there is no secret, and valid? is false' do
    expect(described_class.header(secret: nil, webhook_id: id, timestamp: now.to_i, body: body)).to be_nil
    expect(described_class.valid?(secret: nil, webhook_id: id, timestamp: now.to_i, body: body,
                               signature: 'v1,x', now: now)).to be(false)
  end

  it 'accepts a plain (non-prefixed) shared secret' do
    timestamp = now.to_i
    header = described_class.header(secret: 'plain-shared-secret', webhook_id: id, timestamp: timestamp, body: body)

    expect(described_class.valid?(secret: 'plain-shared-secret', webhook_id: id, timestamp: timestamp,
                               body: body, signature: header, now: now)).to be(true)
  end
end
