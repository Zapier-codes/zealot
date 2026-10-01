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
# Written by reading the code, NOT run (no Ruby, Rails or database in the sandbox that wrote it), so
# it is the first thing to look at if CI is red for this slice.
RSpec.describe 'Manual upload only (f.viii)', type: :request do
  # Every file that turns an uploaded file into a Release, with the auth line it must carry.
  def upload_doors
    {
      'app/controllers/releases_controller.rb' => 'before_action :authenticate_login!',
      'app/controllers/api/apps/upload_controller.rb' => 'before_action :validate_user_token'
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
end
