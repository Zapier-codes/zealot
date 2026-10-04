# frozen_string_literal: true

require 'rails_helper'

# Task 39a (Storeapp Track f, leaf `f.viii`): publishing a distr-provisioned app to the catalog is
# MANUAL-UPLOAD-ONLY. A `distr` build finishing must never, by itself, create a release (and so a
# catalog entry) here. Today that holds because the only code that turns an uploaded file into a
# release sits behind two user-authenticated doors and nothing fetches a file from a URL. This spec
# is the tripwire that keeps it true: it fails the moment a third door appears (a webhook, an
# "import from URL", a job), so adding one has to be a deliberate edit of the lists below and a
# decision on the board (Task 39), not a side effect.
#
# The one allowed exception is a developer publishing through Zealot's own authenticated API in their
# own CI (`POST /api/apps/upload`, the existing user-token door). It is a different trust relationship:
# the caller authenticates against Zealot itself. Its per-app, scoped replacement is leaf `f.xiv`
# (Task 34a); neither `f.viii` nor this spec changes it.
#
# Task 40h-b adds the direct-to-storage doors (a session, then finalize; console and API). They create a
# `release_uploads` staging row, never a `Release`. The examples after the 40h-b marker pin who may write a staging
# row and keep both new doors behind the same two credentials as the multipart ones.
#
# Task 40i-b adds the third creator of releases and the first that has no user session: CI's stage-1 callback.
# It is deliberate, and it is the reason for the last group of examples: the callback authenticates with GitHub's
# OIDC token and nothing else; a recorded report reaches exactly one builder (`ReleaseUploadReleaseBuilder`),
# which is the only code that may mark a release as built from a staged upload (`storage_intake_kind =`); the
# builder is reached only from the report intake, and the intake only from the callback controller; and a
# callback for an upload nobody finalized creates no release.
#
# Task 40i-a adds the stage-1 callback (`POST /api/release_uploads/:id/stage1`). It is a door that needs NO user
# credential, so it is pinned at the end of this file: it must authenticate with the GitHub OIDC verifier before
# anything else, create no release and write no staging row (it only updates one), and refuse every call without
# a valid token.
#
# Written by reading the code, NOT run (no Ruby, Rails or database in the sandbox that wrote it), so
# it is the first thing to look at if CI is red for this slice.
RSpec.describe 'Manual upload only (f.viii)', type: :request do
  # Every file that turns an uploaded file into a Release, with the auth line it must carry.
  def upload_doors
    {
      'app/controllers/releases_controller.rb' => 'before_action :authenticate_login!',
      'app/controllers/api/apps/upload_controller.rb' => 'before_action :validate_user_token, unless: :app_token_presented?'
    }
  end

  # Task 40h-b: the two doors that open and finalize a direct upload, with the auth line each must carry.
  def session_doors
    {
      'app/controllers/release_uploads_controller.rb' => 'before_action :authenticate_user!',
      'app/controllers/api/apps/upload_sessions_controller.rb' =>
        'before_action :validate_user_token, unless: :app_token_presented?'
    }
  end

  def source_files
    Dir[Rails.root.join('app/**/*.rb'), Rails.root.join('lib/**/*.rb')].sort
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end

  it 'has exactly the two known callers of Release.upload_file' do
    callers = source_files.select { |f| File.read(f).match?(/upload_file\(/) }.map { |f| relative(f) }
    callers -= ['app/models/release.rb'] # the definition itself
    expect(callers.sort).to eq(upload_doors.keys.sort)
  end

  it 'creates no release anywhere else through create / create!' do
    offenders = source_files.select do |f|
      File.read(f).match?(/\breleases\.create!?\b|\bRelease\.create!?\b/)
    end
    expect(offenders.map { |f| relative(f) }).to eq([])
  end

  it 'keeps each upload door behind its own authentication' do
    upload_doors.each do |file, auth_line|
      expect(File.read(Rails.root.join(file))).to include(auth_line), "#{file} lost `#{auth_line}`"
    end
  end

  it 'fetches nothing from a URL in either upload door or the release model' do
    files = upload_doors.keys + ['app/models/release.rb']
    files.each do |file|
      text = File.read(Rails.root.join(file))
      expect(text).not_to match(/open-uri|URI\.open|Net::HTTP|Faraday|HTTParty|(remote|download|asset|source)_url/),
                          "#{file} looks like it can pull a file from a URL"
    end
  end

  it 'exposes no inbound hook route except the payment one' do
    hooks = Rails.application.routes.routes.map { |r| r.path.spec.to_s }
                 .select { |p| p.match?(%r{\A/hooks?(/|\()}) }
                 .map { |p| p.sub('(.:format)', '') }
    expect(hooks.uniq).to eq(['/hooks/hyperswitch'])
  end

  it 'refuses an API upload that carries no user token, and creates nothing' do
    expect do
      post '/api/apps/upload', params: { file: 'x', channel_key: 'nope' }
    end.not_to change(Release, :count)
    expect(response).not_to have_http_status(:created)
    expect(response.status).to be >= 400
  end

  it 'refuses an API upload with an unknown token, and creates nothing' do
    expect do
      post '/api/apps/upload', params: { token: 'not-a-real-token', file: 'x' }
    end.not_to change(Release, :count)
    expect(response.status).to be >= 400
  end

  # --- Task 40h-b: the direct-to-storage doors ---

  it 'keeps each direct-upload door behind its own authentication' do
    session_doors.each do |file, auth_line|
      expect(File.read(Rails.root.join(file))).to include(auth_line), "#{file} lost `#{auth_line}`"
    end
  end

  it 'writes a release_uploads row from exactly one place, the session service' do
    offenders = source_files.select do |f|
      File.read(f).match?(
        /\bReleaseUpload\.(create!?|new|insert_all!?|upsert_all?)\b|\brelease_uploads\.(create!?|build)\b/
      )
    end
    expect(offenders.map { |f| relative(f) }).to eq(['app/services/release_upload_session.rb'])
  end

  it 'lets the direct-upload doors create no release and fetch nothing from a URL' do
    session_doors.each_key do |file|
      text = File.read(Rails.root.join(file))
      forbidden = /upload_file|\breleases\.(create|build)|Release\.create|open-uri|URI\.open|Net::HTTP|Faraday/
      expect(text).not_to match(forbidden), "#{file} can create a release or pull a file from a URL"
    end
  end

  it 'refuses an API session with no credential or an unknown token, and creates no row' do
    expect do
      post '/api/apps/upload_sessions', params: { filename: 'x.aab', size: 1, channel_key: 'nope' }
      expect(response.status).to be >= 400
      post '/api/apps/upload_sessions', params: { token: 'not-a-real-token', filename: 'x.aab', size: 1 }
      expect(response.status).to be >= 400
    end.not_to change(ReleaseUpload, :count)
  end

  it 'refuses finalizing an API session with no credential' do
    post '/api/apps/upload_sessions/1/finalize'

    expect(response.status).to be >= 400
  end

  # --- Task 40i-a: the stage-1 callback ---

  it 'puts the OIDC check first in the stage-1 callback and lets it create no release or staging row' do
    text = File.read(Rails.root.join('app/controllers/api/release_upload_callbacks_controller.rb'))

    expect(text).to include('before_action :authenticate_workflow!')
    expect(text).to include('GithubOidcVerifier.new')
    forbidden = Regexp.union(/upload_file/, /\breleases\.(create|build)/, /Release\.create/,
                             /ReleaseUpload\.(create|new)/, /open-uri|URI\.open|Net::HTTP|Faraday/)
    expect(text).not_to match(forbidden)
  end

  it 'lets the report intake build a release only through the builder, and fetch nothing from a URL' do
    text = File.read(Rails.root.join('app/services/release_upload_intake.rb'))

    forbidden = /upload_file|\breleases\.(create|build)|Release\.create|open-uri|URI\.open|Net::HTTP|Faraday/
    expect(text).not_to match(forbidden)
  end

  it 'refuses a stage-1 callback with no token, with the shared compile token, and creates nothing' do
    expect do
      post '/api/release_uploads/1/stage1', params: { state: 'failed' }
      expect(response.status).to be >= 400
      post '/api/release_uploads/1/stage1', params: { state: 'failed' },
                                            headers: { 'Authorization' => 'Bearer not-a-jwt' }
      expect(response.status).to eq(401)
    end.not_to(change { [Release.count, ReleaseUpload.count] })
  end

  # --- Task 40i-b: the callback-side creator ---

  it 'marks a release as built from a staged upload from exactly one place, the release builder' do
    offenders = source_files.select do |f|
      File.read(f).match?(/storage_intake_kind\s*=(?!=)|\bstorage_intake_kind:/)
    end
    expect(offenders.map { |f| relative(f) }).to eq(['app/services/release_upload_release_builder.rb'])
  end

  it 'reaches the release builder from exactly one place, the report intake' do
    callers = source_files.select { |f| File.read(f).match?(/ReleaseUploadReleaseBuilder\.new/) }
                          .map { |f| relative(f) }
    callers -= ['app/services/release_upload_release_builder.rb'] # its own usage example in the header comment
    expect(callers).to eq(['app/services/release_upload_intake.rb'])
  end

  it 'reaches the report intake from exactly one place, the OIDC-guarded stage-1 callback' do
    callers = source_files.select { |f| File.read(f).match?(/ReleaseUploadIntake\.new/) }.map { |f| relative(f) }
    callers -= ['app/services/release_upload_intake.rb'] # its own usage example in the header comment
    expect(callers).to eq(['app/controllers/api/release_upload_callbacks_controller.rb'])
  end

  it 'lets the release builder fetch nothing from a URL and read no file from disk' do
    text = File.read(Rails.root.join('app/services/release_upload_release_builder.rb'))

    expect(text).not_to match(/open-uri|URI\.open|Net::HTTP|Faraday|HTTParty|File\.(read|open|binread)|upload_file/)
  end

  it 'creates no release for an upload nobody finalized, even with a token the verifier accepts' do
    app = create(:app, name: 'Tripwire app')
    channel = app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android)
    upload = ReleaseUpload.create!(channel: channel, filename: 'app.apk', declared_size: 10)
    verifier = instance_double(GithubOidcVerifier, call: {})
    allow(GithubOidcVerifier).to receive(:new).and_return(verifier)
    stub_const('ENV', ENV.to_h.merge('CI_OIDC_AUDIENCE' => 'https://zealot.example'))
    report = { state: 'ok', kind: 'apk', package_name: 'com.example.app', version_code: 1, version_name: '1',
               file_sha256: 'a' * 64, file_size: 10 }

    expect do
      post "/api/release_uploads/#{upload.id}/stage1", params: report.to_json,
                                                       headers: { 'Authorization' => 'Bearer good-token',
                                                                  'Content-Type' => 'application/json' }
    end.not_to change(Release, :count)

    expect(response).to have_http_status(:conflict)
    expect(upload.reload.state).to eq('awaiting_bytes')
  end
end
