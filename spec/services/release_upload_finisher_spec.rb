# frozen_string_literal: true

require 'rails_helper'

# Task 40i-c: the stage-2 report of a staged upload makes the held release installable. Needs Postgres. Storage and
# the staging bucket are doubles. Written by reading the code, NOT run (the operator said no testing; the sandbox
# had Ruby for `ruby -c` only, with no gems); look here first if CI is red for this slice.
RSpec.describe ReleaseUploadFinisher do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:filename) { 'app.apk' }
  let(:kind) { 'apk' }
  let(:options) { {} }
  let(:icon_key) { 'staging/a1/u1/x/icon.png' }
  let(:metadata) do
    { 'kind' => kind, 'package_name' => 'com.example.app', 'version_code' => 12, 'version_name' => '1.2',
      'app_label' => 'Example', 'file_sha256' => 'a' * 64, 'file_size' => 2048,
      'icon_key' => icon_key, 'icon_sha256' => 'b' * 64 }.compact
  end
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: filename, declared_size: 2048, form_options: options)
                 .tap do |row|
      row.update_columns(state: 'uploaded', uploaded_size: 2048, stage1_at: Time.current, metadata: metadata)
    end
  end
  let(:staging) { instance_double(ReleaseUploadStaging, delete: true, delete_sibling: true) }
  let(:storage) { instance_double(ReleaseStorage, exist?: true) }
  let(:env) { {} }

  # Stage 1 and the release builder have run: the row is `processing` and points at a held release.
  let!(:release) do
    ReleaseUploadReleaseBuilder.new(upload.reload, staging: staging).call.release
  end

  let(:keys) do
    ReleaseStorage.new(release, adapter: nil).staged_keys(filename: filename, icon_extension: '.png')
  end
  let(:apk_report) do
    { 'state' => 'ok', 'file_key' => keys[:file], 'file_sha256' => 'a' * 64,
      'icon_key' => keys[:icon], 'icon_sha256' => 'b' * 64 }
  end
  let(:aab_report) do
    apk_report.merge('universal_apk_key' => keys[:universal], 'universal_apk_sha256' => 'C' * 64,
                     'universal_apk_size' => '5000', 'compressed_apks_key' => keys[:compressed],
                     'compressed_size' => '3000', 'cert_sha256' => 'AB:CD')
  end
  let(:report) { apk_report }

  def finish(body = report)
    described_class.new(upload.reload, body, storage: storage, staging: staging, env: env).call
  end

  describe 'an APK report that checks out' do
    it 'records the keys, makes the release available and marks the upload done' do
      result = finish

      expect(result).to have_attributes(code: :finished, http: 200)
      expect(result.payload).to include(upload_id: upload.id, state: 'done', stage: 2, release_id: release.id,
                                        status: 'available')
      expect(release.reload).to have_attributes(
        status: 'available', file_storage_key: keys[:file], icon_storage_key: keys[:icon], icon_sha256: 'b' * 64
      )
      expect(upload.reload.state).to eq('done')
    end

    it 'has the keys under the names the storage adapter maps to the release tag' do
      expect(keys[:file]).to eq("uploads/apps/a#{app.id}/r#{release.id}/binary/app.apk")
      expect(keys[:icon]).to eq("uploads/apps/a#{app.id}/r#{release.id}/icons/icon.png")
    end

    it 'does not set a compile state: an APK is served as it is' do
      finish

      expect(release.reload.ci_compile_state).to be_nil
      expect(release.serves_universal_apk?).to be(false)
      expect(release.file?).to be(true)
    end

    it 'checks the file and the icon are in storage before recording anything' do
      finish

      expect(storage).to have_received(:exist?).with(keys[:file])
      expect(storage).to have_received(:exist?).with(keys[:icon])
    end

    it 'queues the deferred deploy email once the release is available' do
      allow(EmailNotifications).to receive(:enabled?).and_return(true)

      expect { finish }.to have_enqueued_job(ReleaseDeployNotificationJob).with(release.id)
    end

    it 'deletes the staged file and the staged icon' do
      finish

      expect(staging).to have_received(:delete).with(upload)
      expect(staging).to have_received(:delete_sibling).with(upload, icon_key)
    end

    it 'still finishes when the staged objects cannot be deleted' do
      allow(staging).to receive(:delete).and_raise(ReleaseStorage::StorageError, 'R2 is down')

      expect(finish.code).to eq(:finished)
      expect(upload.reload.state).to eq('done')
    end

    context 'when the owner asked to hold the release' do
      let(:options) { { 'hold' => 'true' } }

      it 'records the files but leaves the release held, and sends no email' do
        allow(EmailNotifications).to receive(:enabled?).and_return(true)

        expect { finish }.not_to have_enqueued_job(ReleaseDeployNotificationJob)

        expect(release.reload).to have_attributes(status: 'held', file_storage_key: keys[:file])
        expect(upload.reload.state).to eq('done')
      end
    end

    context 'when stage 1 found no icon' do
      let(:icon_key) { nil }
      let(:apk_report) { { 'state' => 'ok', 'file_key' => keys[:file], 'file_sha256' => 'a' * 64 } }
      let(:keys) { ReleaseStorage.new(release, adapter: nil).staged_keys(filename: filename) }

      it 'records no icon and checks none' do
        finish

        expect(release.reload.icon_storage_key).to be_nil
        expect(storage).to have_received(:exist?).once
        expect(staging).not_to have_received(:delete_sibling)
      end

      it 'refuses a report that claims an icon anyway' do
        result = finish(apk_report.merge('icon_key' => 'uploads/x', 'icon_sha256' => 'b' * 64))

        expect(result).to have_attributes(code: :malformed, http: 422)
        expect(upload.reload.state).to eq('processing')
      end
    end
  end

  # Task 41b: a workflow that names the files after the app is accepted, and so is one that still uses the old names.
  describe 'file names' do
    let(:filename) { 'app-default-release.aab' }
    let(:kind) { 'aab' }
    let(:named_keys) do
      ReleaseStorage.new(release, adapter: nil)
                    .staged_keys(filename: filename, icon_extension: '.png', base: ReleaseArtifactName.for(release))
    end
    let(:named_report) do
      aab_report.merge('file_key' => named_keys[:file], 'icon_key' => named_keys[:icon],
                       'universal_apk_key' => named_keys[:universal], 'compressed_apks_key' => named_keys[:compressed])
    end

    it 'records the app-named keys when the workflow reports them' do
      expect(finish(named_report)).to have_attributes(code: :finished, http: 200)

      expect(release.reload.file_storage_key).to end_with("/binary/#{ReleaseArtifactName.for(release)}.aab")
      expect(release.universal_apk_storage_key).to end_with("/pipeline/#{ReleaseArtifactName.for(release)}.apk")
    end

    it 'still accepts the old names from a workflow that predates the naming' do
      expect(finish(aab_report)).to have_attributes(code: :finished, http: 200)

      expect(release.reload.file_storage_key).to end_with('/binary/app-default-release.aab')
    end

    it 'refuses a mixture of the two' do
      mixed = named_report.merge('universal_apk_key' => keys[:universal])

      expect(finish(mixed)).to have_attributes(code: :malformed, http: 422)
    end
  end

  describe 'a bundle report that checks out' do
    let(:filename) { 'app.aab' }
    let(:kind) { 'aab' }
    let(:report) { aab_report }

    it 'records the universal APK and the split set, so the release is served as the signed universal APK' do
      expect(finish).to have_attributes(code: :finished, http: 200)

      release.reload
      expect(release).to have_attributes(
        status: 'available', ci_compile_state: 'done', file_storage_key: keys[:file],
        universal_apk_storage_key: keys[:universal], universal_apk_sha256: 'c' * 64, universal_apk_size: 5000,
        compressed_apks_storage_key: keys[:compressed], compressed_size: 3000, brotli_compressed: true
      )
      expect(release.serves_universal_apk?).to be(true)
    end

    it 'checks all four objects are in storage' do
      finish

      [keys[:file], keys[:icon], keys[:universal], keys[:compressed]].each do |key|
        expect(storage).to have_received(:exist?).with(key)
      end
    end

    it 'refuses a report whose universal APK is not where Zealot expects it, and changes nothing' do
      result = finish(report.merge('universal_apk_key' => 'uploads/apps/a1/r1/pipeline/other.apk'))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(upload.reload.state).to eq('processing')
      expect(release.reload.status).to eq('held')
    end

    it 'refuses a bad universal hash and a bad size' do
      expect(finish(report.merge('universal_apk_sha256' => 'xyz')).payload[:error]).to match(/64 hex/)
      expect(finish(report.merge('universal_apk_size' => '0')).payload[:error]).to match(/positive integer/)
      expect(upload.reload.state).to eq('processing')
    end

    context 'when the signing certificate is expected' do
      let(:env) { { 'CI_COMPILE_EXPECT_CERT_SHA256' => 'ab:cd' } }

      it 'accepts the matching certificate in either notation' do
        expect(finish.code).to eq(:finished)
      end

      it 'rejects another certificate: the upload fails and the release stays held with the reason' do
        result = finish(report.merge('cert_sha256' => 'ff'))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(upload.reload).to have_attributes(state: 'failed')
        expect(release.reload).to have_attributes(status: 'held', ci_compile_state: 'failed', file_storage_key: nil)
        expect(release.ci_compile_error).to match(/certificate/)
      end

      it 'requires the certificate to be reported' do
        result = finish(report.except('cert_sha256'))

        expect(result).to have_attributes(code: :malformed, http: 422)
        expect(upload.reload.state).to eq('processing')
      end
    end
  end

  # Task 40j: CI injected the Proxies SDK before reporting.
  describe 'SDK injection' do
    it 'records the patched APK\'s hash as the release\'s file hash, and still checks the uploaded file\'s' do
      result = finish(apk_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'E' * 64))

      expect(result).to have_attributes(code: :finished, http: 200)
      expect(release.reload).to have_attributes(status: 'available', file_sha256: 'e' * 64)
    end

    it 'keeps the uploaded file\'s hash when nothing was injected' do
      finish

      expect(release.reload.file_sha256).to eq('a' * 64)
    end

    it 'refuses an injected APK with no valid injected hash, and changes nothing' do
      expect(finish(apk_report.merge('sdk_injected' => true))).to have_attributes(code: :malformed, http: 422)
      expect(finish(apk_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'xyz')).http).to eq(422)
      expect(upload.reload.state).to eq('processing')
    end

    it 'refuses an injected hash that comes without the flag' do
      result = finish(apk_report.merge('injected_file_sha256' => 'e' * 64))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(result.payload[:error]).to match(/without sdk_injected/)
    end

    context 'for a bundle' do
      let(:filename) { 'app.aab' }
      let(:kind) { 'aab' }

      it 'needs nothing extra: the universal APK reported is the patched one, the bundle\'s hash is unchanged' do
        result = finish(aab_report.merge('sdk_injected' => true))

        expect(result).to have_attributes(code: :finished, http: 200)
        expect(release.reload).to have_attributes(file_sha256: 'a' * 64, universal_apk_sha256: 'c' * 64)
      end

      it 'ignores an injected file hash, which only an APK has' do
        result = finish(aab_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'e' * 64))

        expect(result).to have_attributes(code: :finished, http: 200)
        expect(release.reload.file_sha256).to eq('a' * 64)
      end
    end
  end

  # Task 40p: unlike REQUIRE_ORG_SIGNED_APKS there is no variable that lets this through.
  describe 'a pre-existing bandwidth-sharing SDK' do
    it 'rejects the upload and names the SDK(s) CI found, leaving the release held' do
      result = finish(apk_report.merge('preexisting_bandwidth_sdk' => true,
                                       'preexisting_bandwidth_sdk_names' => ['Honeygain']))

      expect(result).to have_attributes(code: :rejected, http: 422)
      expect(result.payload[:error]).to match(/Honeygain/)
      expect(upload.reload.state).to eq('failed')
      expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
    end

    it 'joins more than one matched name into the same reason' do
      result = finish(apk_report.merge('preexisting_bandwidth_sdk' => true,
                                       'preexisting_bandwidth_sdk_names' => %w[Honeygain Repocket]))

      expect(result.payload[:error]).to match(/Honeygain, Repocket/)
    end

    it 'still rejects with a generic reason when CI reported the flag but no names' do
      result = finish(apk_report.merge('preexisting_bandwidth_sdk' => true))

      expect(result).to have_attributes(code: :rejected, http: 422)
      expect(result.payload[:error]).to match(/unidentified bandwidth-sharing SDK/)
    end

    it 'accepts the upload as usual when CI reported false (or nothing)' do
      expect(finish(apk_report.merge('preexisting_bandwidth_sdk' => false)).code).to eq(:finished)
      expect(finish(apk_report).code).to eq(:finished)
    end

    context 'for a bundle' do
      let(:filename) { 'app.aab' }
      let(:kind) { 'aab' }

      it 'rejects exactly the same way as for an APK' do
        result = finish(aab_report.merge('preexisting_bandwidth_sdk' => true,
                                         'preexisting_bandwidth_sdk_names' => ['Grass']))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload[:error]).to match(/Grass/)
      end
    end
  end

  # Task 40l: CI re-signed the uploaded APK with the organisation key before reporting.
  describe 'organisation signing of an APK' do
    let(:signed_report) do
      apk_report.merge('org_signed' => true, 'signed_file_sha256' => 'D' * 64, 'cert_sha256' => 'ab')
    end

    it 'records the signed APK\'s hash as the release\'s file hash, and still checks the uploaded file\'s' do
      result = finish(signed_report)

      expect(result).to have_attributes(code: :finished, http: 200)
      expect(release.reload).to have_attributes(status: 'available', file_sha256: 'd' * 64)
    end

    it 'refuses a signed APK with no valid signed hash, and changes nothing' do
      expect(finish(signed_report.except('signed_file_sha256'))).to have_attributes(code: :malformed, http: 422)
      expect(finish(signed_report.merge('signed_file_sha256' => 'xyz')).http).to eq(422)
      expect(upload.reload.state).to eq('processing')
    end

    it 'refuses a signed hash that comes without the flag' do
      result = finish(apk_report.merge('signed_file_sha256' => 'd' * 64))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(result.payload[:error]).to match(/without org_signed/)
    end

    it 'refuses a report that says both injected and signed' do
      result = finish(signed_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'e' * 64))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(upload.reload.state).to eq('processing')
    end

    context 'when the signing certificate is expected' do
      let(:env) { { 'CI_COMPILE_EXPECT_CERT_SHA256' => 'ab:cd' } }
      let(:signed_report) { super().merge('cert_sha256' => 'ABCD') }

      it 'accepts the matching certificate' do
        expect(finish(signed_report).code).to eq(:finished)
      end

      it 'requires the certificate to be reported' do
        expect(finish(signed_report.except('cert_sha256'))).to have_attributes(code: :malformed, http: 422)
        expect(upload.reload.state).to eq('processing')
      end

      it 'rejects another certificate: the upload fails and the release stays held' do
        result = finish(signed_report.merge('cert_sha256' => 'ff'))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
      end
    end

    context 'for a bundle' do
      let(:filename) { 'app.aab' }
      let(:kind) { 'aab' }

      it 'ignores the flag and the hash: the bundle is not replaced' do
        result = finish(aab_report.merge('org_signed' => true, 'signed_file_sha256' => 'd' * 64))

        expect(result).to have_attributes(code: :finished, http: 200)
        expect(release.reload.file_sha256).to eq('a' * 64)
      end
    end
  end

  # Task 40l-b: a release the flow signed with the organisation key is marked signed, as the old path marks one.
  describe 'recording that the organisation key signed the release' do
    let(:env) { { 'CI_COMPILE_EXPECT_CERT_SHA256' => 'ab:cd' } }
    let(:key) { instance_double(AndroidSigningKey, checksum: 'sum-1') }
    let(:injected_report) do
      apk_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'e' * 64, 'cert_sha256' => 'ABCD')
    end
    let(:signed_report) do
      apk_report.merge('org_signed' => true, 'signed_file_sha256' => 'd' * 64, 'cert_sha256' => 'ABCD')
    end

    before do
      allow(AndroidSigningKey).to receive(:current).and_return(key)
      allow(GoogleAdc).to receive(:auto_register?).and_return(false)
      allow(GoogleAdcRegisterJob).to receive(:perform_later)
    end

    it 'marks an org-signed APK signed, with the key\'s checksum' do
      finish(signed_report)

      expect(release.reload).to have_attributes(signed: true, signing_key_checksum: 'sum-1')
    end

    it 'marks an SDK-injected APK signed, and requires its certificate to be reported' do
      finish(injected_report)
      expect(release.reload).to have_attributes(signed: true, signing_key_checksum: 'sum-1')
    end

    it 'refuses an injected APK that reports no certificate where one is expected' do
      result = finish(injected_report.except('cert_sha256'))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(upload.reload.state).to eq('processing')
    end

    context 'for a bundle' do
      let(:filename) { 'app.aab' }
      let(:kind) { 'aab' }

      it 'marks it signed when the reported certificate matches' do
        finish(aab_report)

        expect(release.reload).to have_attributes(signed: true, signing_key_checksum: 'sum-1')
      end
    end

    it 'does not mark a plain APK that nobody signed in CI' do
      finish(apk_report)

      expect(release.reload).to have_attributes(signed: false, signing_key_checksum: nil)
    end

    context 'when no certificate is expected on this server' do
      let(:env) { {} }

      it 'records the file but marks nothing, since the certificate cannot be confirmed' do
        expect(finish(signed_report).code).to eq(:finished)
        expect(release.reload).to have_attributes(signed: false, signing_key_checksum: nil)
      end
    end

    context 'when there is no organisation key row' do
      before { allow(AndroidSigningKey).to receive(:current).and_return(nil) }

      it 'finishes the upload and marks nothing' do
        expect(finish(signed_report).code).to eq(:finished)
        expect(release.reload.signed).to be(false)
      end
    end

    context 'when Google registration is switched on' do
      before { allow(GoogleAdc).to receive(:auto_register?).and_return(true) }

      it 'queues it for a signed release that became available' do
        finish(signed_report)

        expect(GoogleAdcRegisterJob).to have_received(:perform_later).with(release.id)
      end

      it 'does not queue it for a release that is not marked signed' do
        finish(apk_report)

        expect(GoogleAdcRegisterJob).not_to have_received(:perform_later)
      end

      it 'does not queue it for a release held at session time' do
        upload.update_columns(form_options: { 'hold' => true })
        finish(signed_report)

        expect(GoogleAdcRegisterJob).not_to have_received(:perform_later)
      end

      it 'does not let a queueing failure undo the finished upload' do
        allow(GoogleAdcRegisterJob).to receive(:perform_later).and_raise(StandardError, 'queue down')

        expect(finish(signed_report).code).to eq(:finished)
        expect(release.reload.status).to eq('available')
      end
    end
  end

  # Task 40o: the upload's source decides whether CI's finished report makes the release available
  # right away or leaves it held for the owner to publish once the listing is paid for.
  describe 'the upload source decides whether the release is held' do
    context 'when uploaded via manual dashboard (source: web)' do
      let(:options) { { 'source' => 'web' } }

      it 'leaves the release held and does not enqueue deploy email' do
        allow(EmailNotifications).to receive(:enabled?).and_return(true)

        expect { finish(apk_report) }.not_to have_enqueued_job(ReleaseDeployNotificationJob)

        expect(release.reload).to have_attributes(status: 'held', file_storage_key: keys[:file])
        expect(upload.reload.state).to eq('done')
      end
    end

    context 'when uploaded via API (source: api)' do
      let(:options) { { 'source' => 'api' } }

      it 'makes the release available and enqueues deploy email' do
        allow(EmailNotifications).to receive(:enabled?).and_return(true)

        expect { finish(apk_report) }.to have_enqueued_job(ReleaseDeployNotificationJob)

        expect(release.reload).to have_attributes(status: 'available', file_storage_key: keys[:file])
        expect(upload.reload.state).to eq('done')
      end
    end
  end

  describe 'a report that does not check out' do
    it 'refuses a file key that is not where Zealot expects it, and changes nothing' do
      result = finish(report.merge('file_key' => 'uploads/apps/a9/r9/binary/app.apk'))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(upload.reload.state).to eq('processing')
      expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
    end

    it 'refuses a file hash that differs from the one stage 1 read (a file swapped between the stages)' do
      result = finish(report.merge('file_sha256' => 'd' * 64))

      expect(result).to have_attributes(code: :malformed, http: 422)
      expect(result.payload[:error]).to match(/does not match the file/)
      expect(release.reload.file_storage_key).to be_nil
    end

    it 'refuses an icon hash that differs from the one stage 1 read' do
      result = finish(report.merge('icon_sha256' => 'd' * 64))

      expect(result).to have_attributes(code: :malformed, http: 422)
    end

    it 'rejects a report whose object is not in storage: the upload fails, the release stays held' do
      allow(storage).to receive(:exist?).with(keys[:file]).and_return(false)

      result = finish

      expect(result).to have_attributes(code: :rejected, http: 422)
      expect(result.payload).to include(state: 'failed')
      expect(result.payload[:error]).to include(keys[:file], 'not in storage')
      expect(upload.reload).to have_attributes(state: 'failed')
      expect(release.reload).to have_attributes(status: 'held', ci_compile_state: 'failed', file_storage_key: nil)
    end

    it 'answers 503 and changes nothing when storage cannot be reached' do
      allow(storage).to receive(:exist?).and_raise(ReleaseStorage::StorageError, 'GitHub is down')

      result = finish

      expect(result).to have_attributes(code: :unavailable, http: 503)
      expect(upload.reload.state).to eq('processing')
      expect(release.reload.status).to eq('held')
    end

    it 'answers state-must-be for any other state value' do
      expect(finish('state' => 'maybe')).to have_attributes(code: :malformed, http: 422)
    end
  end

  describe 'a failed report from CI' do
    it 'fails the upload, writes the reason on the held release and leaves it held' do
      result = finish('state' => 'failed', 'error' => 'bundletool ran out of disk')

      expect(result).to have_attributes(code: :failure_recorded, http: 200)
      expect(upload.reload).to have_attributes(state: 'failed', error: 'bundletool ran out of disk')
      expect(release.reload).to have_attributes(status: 'held', ci_compile_state: 'failed',
                                                ci_compile_error: 'bundletool ran out of disk')
    end

    it 'gives a reason when CI sent none' do
      finish('state' => 'failed')

      expect(upload.reload.error).to match(/without a reason/)
    end
  end

  describe 'state and idempotency' do
    it 'answers the same thing for a replay and writes nothing' do
      finish

      expect do
        result = finish
        expect(result).to have_attributes(code: :already_finished, http: 200)
      end.not_to(change { release.reload.updated_at })
    end

    it 'does not queue a second email on a replay' do
      allow(EmailNotifications).to receive(:enabled?).and_return(true)
      finish

      expect { finish }.not_to have_enqueued_job(ReleaseDeployNotificationJob)
    end

    it 'refuses a replay that names a different file' do
      finish

      expect(finish(report.merge('file_sha256' => 'd' * 64))).to have_attributes(code: :conflict, http: 409)
    end

    it 'refuses a report for an upload that is not processing, and never makes a release' do
      upload.update_columns(state: 'uploaded', release_id: nil)

      expect { @result = finish }.not_to change(Release, :count)
      expect(@result).to have_attributes(code: :not_open, http: 409)
    end

    it 'refuses a failure report for an upload that already finished' do
      finish
      expect(finish('state' => 'failed', 'error' => 'late')).to have_attributes(code: :not_open, http: 409)
      expect(release.reload.status).to eq('available')
    end

    it 'refuses to finish an upload the sweeper already failed' do
      upload.update_columns(state: 'failed', error: 'too slow')

      expect(finish).to have_attributes(code: :not_open, http: 409)
      expect(release.reload.file_storage_key).to be_nil
    end
  end
end
