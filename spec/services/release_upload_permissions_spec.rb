# frozen_string_literal: true

require 'rails_helper'

# Task 46a: a release made from a staged upload carries the permissions CI read from the manifest. Stage 1 reports the
# list of the file as uploaded; stage 2 may report the list of the file people will install (after SDK injection) and
# then replaces it. Needs Postgres for the last two groups. Written by reading the code, NOT run (no-testing
# instruction; no Ruby in the sandbox that wrote it): if CI is red, read the first group (pure) before the others.
RSpec.describe 'upload permissions' do
  describe ReleaseUploadIntake, '.clean_permissions' do
    it 'is empty for anything that is not a list' do
      expect(described_class.clean_permissions(nil)).to eq([])
      expect(described_class.clean_permissions('android.permission.INTERNET')).to eq([])
      expect(described_class.clean_permissions({ 'a' => 1 })).to eq([])
    end

    it 'keeps well-formed names, sorted, without duplicates' do
      list = ['android.permission.WAKE_LOCK', 'android.permission.INTERNET', 'android.permission.INTERNET',
              'com.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION']

      expect(described_class.clean_permissions(list)).to eq(
        ['android.permission.INTERNET', 'android.permission.WAKE_LOCK',
         'com.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION']
      )
    end

    it 'drops anything that is not a permission name instead of refusing the report' do
      list = ['android.permission.INTERNET', '', 'no spaces allowed', 'nodots', '1bad.start', '$(rm -rf).x', nil, 5,
              "android.permission.X\nY", "#{'a' * 300}.b"]

      expect(described_class.clean_permissions(list)).to eq(['android.permission.INTERNET'])
    end

    it 'keeps at most MAX_PERMISSIONS names' do
      list = Array.new(ReleaseUploadIntake::MAX_PERMISSIONS + 20) { |i| format('com.example.P%04d', i) }

      expect(described_class.clean_permissions(list).length).to eq(ReleaseUploadIntake::MAX_PERMISSIONS)
    end
  end

  describe 'on a release made from a report' do
    let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
    let(:scheme) { app.schemes.create!(name: 'Main') }
    let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
    let(:stage1_permissions) { ['android.permission.INTERNET'] }
    let(:metadata) do
      { 'kind' => 'apk', 'package_name' => 'com.example.app', 'version_code' => 12, 'version_name' => '1.2',
        'app_label' => 'Example', 'file_sha256' => 'a' * 64, 'file_size' => 2048,
        'permissions' => stage1_permissions }
    end
    let!(:upload) do
      ReleaseUpload.create!(channel: channel, filename: 'app.apk', declared_size: 2048, form_options: {})
                   .tap do |row|
        row.update_columns(state: 'uploaded', uploaded_size: 2048, stage1_at: Time.current, metadata: metadata)
      end
    end
    let(:staging) { instance_double(ReleaseUploadStaging, delete: true, delete_sibling: true) }
    let(:storage) { instance_double(ReleaseStorage, exist?: true) }

    def build_release
      ReleaseUploadReleaseBuilder.new(upload.reload, staging: staging).call.release
    end

    it 'the builder stores the stage-1 permissions on the held release' do
      expect(build_release.reload.permissions).to eq(stage1_permissions)
    end

    context 'when stage 1 sent no permissions' do
      let(:stage1_permissions) { nil }

      it 'the release has an empty list, as before' do
        expect(build_release.reload.permissions).to eq([])
      end
    end

    describe 'stage 2' do
      let!(:release) { build_release }
      let(:keys) { ReleaseStorage.new(release, adapter: nil).staged_keys(filename: 'app.apk', icon_extension: '.png') }
      let(:report) { { 'state' => 'ok', 'file_key' => keys[:file], 'file_sha256' => 'a' * 64 } }

      def finish(body)
        ReleaseUploadFinisher.new(upload.reload, body, storage: storage, staging: staging, env: {}).call
      end

      it 'replaces the list with the one read from the installable file' do
        installed = ['android.permission.FOREGROUND_SERVICE', 'android.permission.INTERNET']

        finish(report.merge('permissions' => installed))

        expect(release.reload.permissions).to eq(installed)
      end

      it 'keeps the stage-1 list when stage 2 sends none' do
        finish(report)

        expect(release.reload.permissions).to eq(stage1_permissions)
      end

      it 'keeps the stage-1 list when stage 2 sends only garbage' do
        finish(report.merge('permissions' => ['not a permission', '']))

        expect(release.reload.permissions).to eq(stage1_permissions)
      end
    end
  end
end
