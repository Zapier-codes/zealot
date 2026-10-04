# frozen_string_literal: true

require 'rails_helper'

# Task 40i-a: what the stage-1 report may change on a release_uploads row. Needs Postgres. NOT run.
RSpec.describe ReleaseUploadIntake do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.apk', declared_size: 2048).tap do |row|
      row.update_columns(state: 'uploaded', uploaded_size: 2048, uploaded_at: Time.current)
    end
  end
  let(:sha) { 'a' * 64 }
  let(:icon_key) { "#{File.dirname(upload.staging_key)}/icon.png" }
  let(:body) do
    { 'state' => 'ok', 'kind' => 'apk', 'package_name' => 'com.example.app', 'version_code' => 12,
      'version_name' => '1.2', 'app_label' => 'Example', 'min_sdk' => 21, 'target_sdk' => 34,
      'abis' => %w[arm64-v8a x86_64], 'file_sha256' => sha, 'file_size' => 2048,
      'icon_key' => icon_key, 'icon_sha256' => 'b' * 64 }
  end
  let(:staging) { instance_double(ReleaseUploadStaging, delete: true) }

  def intake(payload = body)
    described_class.new(upload.reload, payload, staging: staging).call
  end

  it 'stores the normalized report, stamps stage1_at and creates no release' do
    expect { @result = intake }.not_to change(Release, :count)

    expect(@result.code).to eq(:recorded)
    expect(@result.http).to eq(200)
    expect(@result.payload).to include(upload_id: upload.id, stage: 1, release_id: nil,
                                       package_name: 'com.example.app')
    upload.reload
    expect(upload.state).to eq('uploaded')
    expect(upload.stage1_at).to be_present
    expect(upload.metadata).to include('package_name' => 'com.example.app', 'version_code' => 12,
                                       'file_sha256' => sha, 'icon_key' => icon_key)
  end

  it 'answers the same report again with 200 and writes nothing' do
    intake
    stamp = upload.reload.stage1_at

    result = intake
    expect(result.code).to eq(:already_recorded)
    expect(result.http).to eq(200)
    expect(upload.reload.stage1_at).to eq(stamp)
  end

  it 'refuses a different report for an upload that already has one' do
    intake
    result = intake(body.merge('file_sha256' => 'c' * 64))

    expect(result.code).to eq(:conflict)
    expect(result.http).to eq(409)
    expect(upload.reload.metadata['file_sha256']).to eq(sha)
  end

  it 'refuses a report for an upload that is not uploaded' do
    upload.update_columns(state: 'awaiting_bytes')
    result = intake

    expect(result.code).to eq(:not_open)
    expect(result.http).to eq(409)
    expect(upload.reload.stage1_at).to be_nil
  end

  {
    'a bad package name' => { 'package_name' => 'not a package' },
    'a one-segment package name' => { 'package_name' => 'single' },
    'a zero version code' => { 'version_code' => 0 },
    'a non-numeric version code' => { 'version_code' => 'abc' },
    'a missing version name' => { 'version_name' => '' },
    'a short hash' => { 'file_sha256' => 'abc' },
    'a size that is not the staged size' => { 'file_size' => 1 },
    'a kind that does not match the file name' => { 'kind' => 'aab' },
    'an unknown kind' => { 'kind' => 'zip' },
    'an out-of-range SDK level' => { 'min_sdk' => 500 },
    'too many ABIs' => { 'abis' => Array.new(17) { |i| "abi#{i}" } },
    'a bad ABI name' => { 'abis' => ['arm 64'] },
    'an icon key without a hash' => { 'icon_sha256' => nil },
    'an icon under another upload' => { 'icon_key' => 'staging/a1/u999/ffff/icon.png' },
    'an icon key that climbs out' => { 'icon_key' => nil }
  }.each do |label, change|
    it "refuses #{label} with 422 and changes nothing" do
      payload = body.merge(change)
      payload['icon_key'] = "#{File.dirname(upload.staging_key)}/../x.png" if label.include?('climbs')
      result = intake(payload)

      expect(result.code).to eq(:malformed)
      expect(result.http).to eq(422)
      upload.reload
      expect(upload.stage1_at).to be_nil
      expect(upload.metadata).to eq({})
    end
  end

  it 'accepts a report with no icon' do
    result = intake(body.except('icon_key', 'icon_sha256'))

    expect(result.code).to eq(:recorded)
    expect(upload.reload.metadata).not_to have_key('icon_key')
  end

  it 'marks the upload failed on a failure report and drops the staged object' do
    result = intake('state' => 'failed', 'error' => 'the manifest has no package line')

    expect(result.code).to eq(:failure_recorded)
    upload.reload
    expect(upload.state).to eq('failed')
    expect(upload.error).to eq('the manifest has no package line')
    expect(staging).to have_received(:delete)
  end

  it 'ignores a failure report once stage 1 has already reported' do
    intake
    result = intake('state' => 'failed', 'error' => 'late')

    expect(result.code).to eq(:not_open)
    expect(upload.reload.state).to eq('uploaded')
  end

  it 'refuses a report whose state is neither ok nor failed' do
    expect(intake(body.merge('state' => 'maybe')).http).to eq(422)
  end
end
