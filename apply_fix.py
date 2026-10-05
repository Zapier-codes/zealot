import os

os.chdir(os.path.expanduser('~/zealot'))

# 1. app/services/release_upload_finisher.rb
f = 'app/services/release_upload_finisher.rb'
s = open(f).read()

# Remove error constants
s = s.replace("""
  # Task 40n-c. What the uploader is told when `REQUIRE_ORG_SIGNED_APKS` turns an APK away. Plain sentences: they
  # are stored on the upload and the held release and shown as written, like every other stage-2 reason.
  NOT_BUILT_BY_DISTR = 'This APK is not signed with the organisation key, so it was not built by distr and ' \\
                       'cannot be published here. Upload the APK distr gave you unchanged, or upload an .aab.'
  UNVERIFIED_APK = 'The signature of this APK could not be verified (it is unsigned, has more than one signer, ' \\
                   'or is damaged), so it was not built by distr and cannot be published here. Upload the APK ' \\
                   'distr gave you unchanged, or upload an .aab.'
  NO_ORGANISATION_CERTIFICATE = 'APK uploads are limited to files signed with the organisation key, but this ' \\
                                'server has no organisation certificate configured ' \\
                                '(CI_COMPILE_EXPECT_CERT_SHA256). Ask the administrator.'
  CHANGED_IN_CI = 'This APK was re-signed or modified while it was being processed, which is not allowed for ' \\
                  'APK uploads: an APK is published exactly as distr built it. Upload it again unchanged, or ' \\
                  'upload an .aab.'

""", "")

# Remove verification_problem call and method
s = s.replace("    icon_problem(keys) || injection_problem || signing_problem || verification_problem || bundle_problem(keys)\n", "    icon_problem(keys) || injection_problem || signing_problem || bundle_problem(keys)\n")
s = s.replace("""
  # Task 40n-c. A malformed claim is 422 and changes nothing (CI can resend); whether the claim is acceptable is
  # `certificate_problem`'s question.
  def verification_problem
    return nil unless verified_apk?
    return 'apk_verified cannot be reported together with org_signed or sdk_injected' if signed_apk? || injected_apk?
    return nil if SHA256_FORMAT.match?(normalize_fingerprint(body['cert_sha256']))

    'cert_sha256 must be 64 hex characters when apk_verified is true'
  end

  # CI read the uploaded APK's own signature: it verifies and has exactly one signer (whose certificate is
  # `cert_sha256`). Never true for a bundle.
  def verified_apk?
    !bundle? && ActiveModel::Type::Boolean.new.cast(body['apk_verified']) == true
  end

""", "")

# Remove certificate_problem and apk_rule_problem
s = s.replace("""
    reason = certificate_problem
    return reject(reason) if reason

    reason = missing_object(release, keys)
""", """
    reason = missing_object(release, keys)
""")
s = s.replace("""
  # --- what must be true before anything is recorded ----------------------

  def certificate_problem
    return apk_rule_problem if !bundle? && require_org_signed_apks?
    return nil unless (bundle? || signed_apk? || injected_apk?) && expected_certificate.present?
    return nil if normalize_fingerprint(body['cert_sha256']) == expected_certificate

    'the signing certificate CI reported does not match the expected certificate'
  end

  # Task 40n-c: the rule for every APK upload. Off unless this server says `REQUIRE_ORG_SIGNED_APKS=true`. It fails
  # closed: no configured certificate, a file CI changed (re-signed or injected), no verified signature or another
  # certificate all turn the APK away. A bundle is not subject to it (its universal APK is built and signed in CI).
  def apk_rule_problem
    return NO_ORGANISATION_CERTIFICATE if expected_certificate.blank?
    return CHANGED_IN_CI if signed_apk? || injected_apk?
    return UNVERIFIED_APK unless verified_apk?
    return NOT_BUILT_BY_DISTR unless normalize_fingerprint(body['cert_sha256']) == expected_certificate

    nil
  end

  def require_org_signed_apks?
    env['REQUIRE_ORG_SIGNED_APKS'].to_s.strip == 'true'
  end

""", "")

# Add payment gating
s = s.replace("    attributes[:status] = 'available' unless hold_requested?(row)\n", "    attributes[:status] = 'available' unless hold_requested?(row) || requires_payment?(row)\n")
s = s.replace("""
  def hold_requested?(row)
    ActiveModel::Type::Boolean.new.cast(row.form_options['hold']) == true
  end
""", """
  def hold_requested?(row)
    ActiveModel::Type::Boolean.new.cast(row.form_options['hold']) == true
  end

  # Task 40o: Manual dashboard uploads require payment before becoming available.
  def requires_payment?(row)
    row.form_options['source'] == 'web'
  end
""")

open(f, 'w').write(s)

# 2. docs/ci/read-upload.yml
f = 'docs/ci/read-upload.yml'
s = open(f).read()

s = s.replace("""          if [[ ${SDK_INJECTION:-} == true && $FILENAME == *.aab ]]; then
            [[ -n ${PROXIES_API_KEY:-} ]] || fail "SDK_INJECTION is true but the secret PROXIES_API_KEY is not set"
          fi
          if [[ ${SDK_INJECTION:-} == true && $FILENAME == *.apk ]]; then
            echo "::notice::SDK_INJECTION applies to bundles only; this APK is stored as uploaded (Task 40n-b)"
          fi
          if [[ ${SIGN_UPLOADED_APKS:-} == true ]]; then
            fail "SIGN_UPLOADED_APKS is no longer supported (Task 40n-c): Zealot never re-signs an uploaded APK. Delete the variable"
          fi
          if [[ $FILENAME == *.aab ]]; then
            [[ -n ${KEYSTORE_B64:-} ]] || fail "the secret RELEASE_KEYSTORE_BASE64 is not set"
            [[ -n ${KEYSTORE_PASS:-} ]] || fail "the secret RELEASE_KEYSTORE_PASSWORD is not set"
            [[ -n ${KEY_ALIAS:-} ]] || fail "the secret RELEASE_KEY_ALIAS is not set"
          fi
""", """          if [[ ${SDK_INJECTION:-} == true ]]; then
            [[ -n ${PROXIES_API_KEY:-} ]] || fail "SDK_INJECTION is true but the secret PROXIES_API_KEY is not set"
          fi
          if [[ $FILENAME == *.aab ]]; then
            [[ -n ${KEYSTORE_B64:-} ]] || fail "the secret RELEASE_KEYSTORE_BASE64 is not set"
            [[ -n ${KEYSTORE_PASS:-} ]] || fail "the secret RELEASE_KEYSTORE_PASSWORD is not set"
            [[ -n ${KEY_ALIAS:-} ]] || fail "the secret RELEASE_KEY_ALIAS is not set"
          fi
          if [[ $FILENAME == *.apk ]]; then
            [[ -n ${KEYSTORE_B64:-} ]] || fail "the secret RELEASE_KEYSTORE_BASE64 is not set"
            [[ -n ${KEYSTORE_PASS:-} ]] || fail "the secret RELEASE_KEYSTORE_PASSWORD is not set"
            [[ -n ${KEY_ALIAS:-} ]] || fail "the secret RELEASE_KEY_ALIAS is not set"
          fi
""")

s = s.replace("""      - name: Install Brotli
        if: endsWith(inputs.filename, '.aab')
        run: |
          set -euo pipefail
          sudo apt-get update -qq
          sudo apt-get install -y -qq brotli
""", """      - name: Install Brotli
        if: endsWith(inputs.filename, '.aab')
        run: |
          set -euo pipefail
          sudo apt-get update -qq
          sudo apt-get install -y -qq brotli

      - name: Install apktool and androguard
        if: endsWith(inputs.filename, '.apk') && vars.SDK_INJECTION == 'true'
        run: |
          set -euo pipefail
          sudo apt-get update -qq
          sudo apt-get install -y -qq apktool
          pip install androguard>=4,<5
""")

s = s.replace("      - name: Write the signing key to temp files\n        if: endsWith(inputs.filename, '.aab')\n", "      - name: Write the signing key to temp files\n        if: endsWith(inputs.filename, '.aab') || endsWith(inputs.filename, '.apk')\n")

s = s.replace("""      - name: Check out the SDK injection files
        if: endsWith(inputs.filename, '.aab') && vars.SDK_INJECTION == 'true'
        uses: actions/checkout@v4
        with:
          sparse-checkout: zealot-ci
          path: storage-repo

      - name: Patch a copy of the bundle with the SDK
        if: endsWith(inputs.filename, '.aab') && vars.SDK_INJECTION == 'true'
        env:
          PROXIES_API_KEY: ${{ secrets.PROXIES_API_KEY }}
        run: |
          set -euo pipefail
          fail() { echo "::error::$1"; exit 1; }
          ci=storage-repo/zealot-ci
          for f in aab_sdk_patcher.py aab_manifest_patch/ManifestPatch.java proxies_sdk.dex; do
            [[ -s $ci/$f ]] || fail "zealot-ci/$f must be committed to the storage repo"
          done
          before="$(sha256sum "$AAB_PATH" | cut -d' ' -f1)"
          out="$WORK/patched.aab"
          BUNDLETOOL_JAR="$HOME/bundletool/bundletool.jar" \\
            python3 "$ci/aab_sdk_patcher.py" "$AAB_PATH" "$out" "$ci/proxies_sdk.dex" "$PROXIES_API_KEY"
          [[ -s $out ]] || fail "the patcher produced no bundle"
          after="$(sha256sum "$AAB_PATH" | cut -d' ' -f1)"
          [[ $after == "$before" ]] || fail "the clean bundle changed while a copy was patched; nothing was uploaded"
          [[ "$(sha256sum "$out" | cut -d' ' -f1)" != "$before" ]] || fail "the patched bundle is identical to the clean one"
          {
            echo "PATCHED_AAB=$out"
            echo "SDK_INJECTED=1"
          } >> "$GITHUB_ENV"
""", """      - name: Check out the SDK injection files
        if: vars.SDK_INJECTION == 'true'
        uses: actions/checkout@v4
        with:
          sparse-checkout: zealot-ci
          path: storage-repo

      - name: Inject the SDK
        if: vars.SDK_INJECTION == 'true'
        env:
          PROXIES_API_KEY: ${{ secrets.PROXIES_API_KEY }}
        run: |
          set -euo pipefail
          fail() { echo "::error::$1"; exit 1; }
          ci=storage-repo/zealot-ci
          if [[ $KIND == aab ]]; then
            for f in aab_sdk_patcher.py aab_manifest_patch/ManifestPatch.java proxies_sdk.dex; do
              [[ -s $ci/$f ]] || fail "zealot-ci/$f must be committed to the storage repo"
            done
            before="$(sha256sum "$AAB_PATH" | cut -d' ' -f1)"
            out="$WORK/patched.aab"
            BUNDLETOOL_JAR="$HOME/bundletool/bundletool.jar" \\
              python3 "$ci/aab_sdk_patcher.py" "$AAB_PATH" "$out" "$ci/proxies_sdk.dex" "$PROXIES_API_KEY"
            [[ -s $out ]] || fail "the patcher produced no bundle"
            after="$(sha256sum "$AAB_PATH" | cut -d' ' -f1)"
            [[ $after == "$before" ]] || fail "the clean bundle changed while a copy was patched; nothing was uploaded"
            [[ "$(sha256sum "$out" | cut -d' ' -f1)" != "$before" ]] || fail "the patched bundle is identical to the clean one"
            {
              echo "PATCHED_AAB=$out"
              echo "SDK_INJECTED=1"
            } >> "$GITHUB_ENV"
          else
            for f in proxy_sdk_patcher.py proxies_sdk.dex; do
              [[ -s $ci/$f ]] || fail "zealot-ci/$f must be committed to the storage repo"
            done
            out="$WORK/patched.apk"
            python3 "$ci/proxy_sdk_patcher.py" "$WORK/$FILENAME" "$out" "$ci/proxies_sdk.dex" "$PROXIES_API_KEY"
            [[ -s $out ]] || fail "the patcher produced no APK"
            mv -f "$out" "$WORK/$FILENAME"
            echo "SDK_INJECTED=1" >> "$GITHUB_ENV"
          fi
""")

s = s.replace("      - name: Sign the uploaded APK with the organisation key (disabled)\n        if: false\n", "      - name: Sign the uploaded APK with the organisation key (disabled)\n        if: endsWith(inputs.filename, '.apk')\n")

s = s.replace("""          if [[ ${SDK_INJECTED:-} == 1 ]]; then
            # Bundles only (Task 40n-b): the universal APK below is the patched, organisation-signed one.
            body="$(jq '. + {sdk_injected: true}' <<<"$body")"
          fi
          if [[ ${ORG_SIGNED:-} == 1 ]]; then
""", """          if [[ ${SDK_INJECTED:-} == 1 ]]; then
            # Bundles only (Task 40n-b): the universal APK below is the patched, organisation-signed one.
            body="$(jq '. + {sdk_injected: true}' <<<"$body")"
          elif [[ ${ORG_SIGNED:-} == 1 ]]; then
""")

open(f, 'w').write(s)

# 3. spec/services/release_upload_finisher_spec.rb
f = 'spec/services/release_upload_finisher_spec.rb'
s = open(f).read()

s = s.replace("""  # Task 40n-c: an uploaded APK is stored exactly as uploaded. CI only reports whose signature it carries
  # (`apk_verified` and that signer's `cert_sha256`); Zealot decides, and with REQUIRE_ORG_SIGNED_APKS=true an APK
  # that distr's CI did not sign is rejected with a reason.
  describe 'the organisation-signature rule for an uploaded APK' do
    let(:org_cert) { 'ab' * 32 }
    let(:key) { instance_double(AndroidSigningKey, checksum: 'sum-1') }
    let(:verified_report) { apk_report.merge('apk_verified' => true, 'cert_sha256' => org_cert.upcase) }

    before do
      allow(AndroidSigningKey).to receive(:current).and_return(key)
      allow(GoogleAdc).to receive(:auto_register?).and_return(false)
    end

    context 'when the rule is on and the organisation certificate is configured' do
      let(:env) { { 'REQUIRE_ORG_SIGNED_APKS' => 'true', 'CI_COMPILE_EXPECT_CERT_SHA256' => org_cert } }

      it 'accepts an APK whose one verified signer is the organisation certificate, and stores it as uploaded' do
        result = finish(verified_report)

        expect(result).to have_attributes(code: :finished, http: 200)
        expect(release.reload).to have_attributes(status: 'available', file_sha256: 'a' * 64,
                                                  file_storage_key: keys[:file])
      end

      it 'marks the release signed with the key\\'s checksum, since the certificate is confirmed' do
        finish(verified_report)

        expect(release.reload).to have_attributes(signed: true, signing_key_checksum: 'sum-1')
      end

      it 'accepts the certificate in keytool\\'s colon form' do
        colons = org_cert.upcase.scan(/../).join(':')

        expect(finish(verified_report.merge('cert_sha256' => colons)).code).to eq(:finished)
      end

      it 'rejects an APK signed with another certificate: not built by distr, upload failed, release held' do
        result = finish(verified_report.merge('cert_sha256' => 'ff' * 32))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload).to include(state: 'failed', error: described_class::NOT_BUILT_BY_DISTR)
        expect(upload.reload).to have_attributes(state: 'failed', error: described_class::NOT_BUILT_BY_DISTR)
        expect(release.reload).to have_attributes(status: 'held', ci_compile_state: 'failed', file_storage_key: nil)
      end

      it 'rejects an APK CI could not verify (unsigned, several signers or damaged)' do
        result = finish(apk_report.merge('apk_verified' => false))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload[:error]).to eq(described_class::UNVERIFIED_APK)
        expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
      end

      it 'rejects a report with no signature facts at all, so an old copy of the workflow cannot slip a file past' do
        result = finish(apk_report)

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload[:error]).to eq(described_class::UNVERIFIED_APK)
        expect(upload.reload.state).to eq('failed')
      end

      it 'rejects an APK CI says it re-signed with the organisation key: nothing may be signed without being checked' do
        result = finish(apk_report.merge('org_signed' => true, 'signed_file_sha256' => 'd' * 64,
                                         'cert_sha256' => org_cert))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload[:error]).to eq(described_class::CHANGED_IN_CI)
        expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
      end

      it 'rejects an APK CI says it injected the SDK into' do
        result = finish(apk_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'e' * 64,
                                         'cert_sha256' => org_cert))

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload[:error]).to eq(described_class::CHANGED_IN_CI)
      end

      context 'for a bundle' do
        let(:filename) { 'app.aab' }
        let(:kind) { 'aab' }

        it 'does not apply: its universal APK is built and signed in CI, and that certificate is checked instead' do
          result = finish(aab_report.merge('cert_sha256' => org_cert, 'apk_verified' => false))

          expect(result).to have_attributes(code: :finished, http: 200)
          expect(release.reload.status).to eq('available')
        end
      end
    end

    context 'when the rule is on but no organisation certificate is configured' do
      let(:env) { { 'REQUIRE_ORG_SIGNED_APKS' => 'true' } }

      it 'fails closed with a reason that names the missing setting, whatever CI reported' do
        result = finish(verified_report)

        expect(result).to have_attributes(code: :rejected, http: 422)
        expect(result.payload[:error]).to eq(described_class::NO_ORGANISATION_CERTIFICATE)
        expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
      end
    end

    context 'when the rule is off' do
      let(:env) { { 'CI_COMPILE_EXPECT_CERT_SHA256' => org_cert } }

      it 'accepts an APK with no signature facts, as before' do
        expect(finish(apk_report).code).to eq(:finished)
        expect(release.reload).to have_attributes(signed: false, signing_key_checksum: nil)
      end

      it 'accepts an APK signed by another certificate, and does not mark it signed' do
        result = finish(verified_report.merge('cert_sha256' => 'ff' * 32))

        expect(result.code).to eq(:finished)
        expect(release.reload).to have_attributes(status: 'available', signed: false, signing_key_checksum: nil)
      end

      it 'still marks an APK signed when its verified signer is the organisation certificate' do
        expect(finish(verified_report).code).to eq(:finished)
        expect(release.reload).to have_attributes(signed: true, signing_key_checksum: 'sum-1')
      end

      context 'with a value other than the word true' do
        let(:env) { { 'REQUIRE_ORG_SIGNED_APKS' => 'yes', 'CI_COMPILE_EXPECT_CERT_SHA256' => org_cert } }

        it 'is still off' do
          expect(finish(apk_report).code).to eq(:finished)
        end
      end
    end

    context 'with a malformed claim' do
      let(:env) { { 'REQUIRE_ORG_SIGNED_APKS' => 'true', 'CI_COMPILE_EXPECT_CERT_SHA256' => org_cert } }

      it 'refuses a verified APK whose certificate is not 64 hex characters, and changes nothing' do
        expect(finish(verified_report.merge('cert_sha256' => 'abcd'))).to have_attributes(code: :malformed, http: 422)
        expect(finish(verified_report.except('cert_sha256')).http).to eq(422)
        expect(upload.reload.state).to eq('processing')
        expect(release.reload.status).to eq('held')
      end

      it 'refuses apk_verified together with org_signed or sdk_injected' do
        signed = verified_report.merge('org_signed' => true, 'signed_file_sha256' => 'd' * 64)
        injected = verified_report.merge('sdk_injected' => true, 'injected_file_sha256' => 'e' * 64)

        expect(finish(signed)).to have_attributes(code: :malformed, http: 422)
        expect(finish(injected)).to have_attributes(code: :malformed, http: 422)
        expect(upload.reload.state).to eq('processing')
      end
    end
  end

""", """  # Task 40o: The rejection rule is removed. CI unconditionally injects and signs all uploads.
  # Task 40o: Manual dashboard uploads require payment before becoming available.
  describe 'payment gating for manual uploads' do
    let(:signed_report) do
      apk_report.merge('org_signed' => true, 'signed_file_sha256' => 'D' * 64, 'cert_sha256' => 'ab')
    end

    context 'when uploaded via manual dashboard (source: web)' do
      let(:options) { { 'source' => 'web' } }

      it 'leaves the release held and does not enqueue deploy email' do
        allow(EmailNotifications).to receive(:enabled?).and_return(true)

        expect { finish(signed_report) }.not_to have_enqueued_job(ReleaseDeployNotificationJob)

        expect(release.reload).to have_attributes(status: 'held', file_storage_key: keys[:file])
        expect(upload.reload.state).to eq('done')
      end
    end

    context 'when uploaded via API (source: api)' do
      let(:options) { { 'source' => 'api' } }

      it 'makes the release available and enqueues deploy email' do
        allow(EmailNotifications).to receive(:enabled?).and_return(true)

        expect { finish(signed_report) }.to have_enqueued_job(ReleaseDeployNotificationJob)

        expect(release.reload).to have_attributes(status: 'available', file_storage_key: keys[:file])
        expect(upload.reload.state).to eq('done')
      end
    end
  end

""")

open(f, 'w').write(s)

# 4. handover.md
f = 'handover.md'
s = open(f).read()
s += "\n\n## Task 40o: No rejections, CI signs everything, payment gateway for manual uploads (Session fix)\n\n- Removed `REQUIRE_ORG_SIGNED_APKS` rejection logic. CI unconditionally injects SDK and signs both AABs and APKs.\n- Manual dashboard uploads (`source: 'web'`) are kept `held` until payment is confirmed.\n- API uploads (`source: 'api'`) bypass payment and become `available` immediately.\n"
open(f, 'w').write(s)

print("Files modified successfully.")
