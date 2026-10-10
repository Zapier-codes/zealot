# frozen_string_literal: true

require 'rails_helper'

# Z-P25 §2: the read side of the Play Developer API. Same shape and same never-raises contract as
# PlayPreflightService, so the stubbing style matches that spec. The service shells out to Google's
# documented gem shape, which is not installed in the sandbox this was written in, so the client is
# always doubled here — the point is the mapping and the Result codes, not Google's own behaviour.
RSpec.describe Anthropic::PlayImportService do
  let(:credential) { instance_double(PlayCredential, service_account_email: 'publishing@example.iam.gserviceaccount.com') }
  let(:client) { double('AndroidPublisherService') }
  let(:package) { 'com.example.app' }

  subject(:service) { described_class.new(credential: credential) }

  before do
    allow(credential).to receive(:with_credentials_file).and_yield('/tmp/play-credentials.json')
    allow(service).to receive(:build_client).and_return(client)
  end

  def listing(language:, title: nil, short: nil, full: nil)
    double('Listing', language: language, title: title, short_description: short, full_description: full)
  end

  def track(track:, releases: [])
    double('Track', track: track, releases: releases)
  end

  it 'reports no_package_name without calling Google when the package is blank' do
    expect(service).not_to receive(:build_client)

    result = service.fetch('  ')

    expect(result.code).to eq(:no_package_name)
    expect(result).not_to be_ok
  end

  it 'reports not_configured when there is no credential' do
    result = described_class.new(credential: nil).fetch(package)

    expect(result.code).to eq(:not_configured)
  end

  it 'reads listings and tracks, then discards the edit without committing' do
    allow(client).to receive(:insert_edit).with(package, {}).and_return(double(id: 'edit-1'))
    allow(client).to receive(:list_edit_listings).with(package, 'edit-1')
      .and_return(double(listings: [listing(language: 'en-US', title: 'My App', short: 'Short', full: "L1\nL2")]))
    allow(client).to receive(:list_edit_tracks).with(package, 'edit-1')
      .and_return(double(tracks: [track(track: 'production',
                                       releases: [double(status: 'completed', version_codes: %w[12 13])])]))
    expect(client).to receive(:delete_edit).with(package, 'edit-1')
    expect(client).not_to receive(:commit_edit)

    result = service.fetch(package)

    expect(result).to be_ok
    expect(result.package_name).to eq(package)
    expect(result.listings.size).to eq(1)
    expect(result.listings.first.title).to eq('My App')
    expect(result.listings.first.full_description).to eq("L1\nL2")
    expect(result.tracks.first.track).to eq('production')
    expect(result.tracks.first.status).to eq('completed')
    expect(result.tracks.first.version_codes).to eq(%w[12 13])
  end

  it 'prefers en-US, then any English, then the first listing' do
    en_us = Anthropic::PlayImportService::Listing.new(language: 'en-US', title: 'US')
    en_gb = Anthropic::PlayImportService::Listing.new(language: 'en-GB', title: 'GB')
    fr = Anthropic::PlayImportService::Listing.new(language: 'fr-FR', title: 'FR')

    result = Anthropic::PlayImportService::Result.new(code: :ok, listings: [fr, en_gb, en_us])

    expect(result.preferred_listing).to eq(en_us)
    expect(Anthropic::PlayImportService::Result.new(code: :ok, listings: [fr, en_gb]).preferred_listing).to eq(en_gb)
    expect(Anthropic::PlayImportService::Result.new(code: :ok, listings: [fr]).preferred_listing).to eq(fr)
    expect(Anthropic::PlayImportService::Result.new(code: :ok, listings: []).preferred_listing).to be_nil
  end

  it 'collapses a track whose releases repeat the status' do
    info = Anthropic::PlayImportService::TrackInfo.from_play(
      track(track: 'alpha', releases: [double(status: 'completed', version_codes: %w[1]),
                                       double(status: 'completed', version_codes: %w[2])])
    )

    expect(info.status).to eq('completed')
    expect(info.version_codes).to eq(%w[1 2])
  end

  it 'maps a 404 to package_not_found' do
    allow(client).to receive(:insert_edit)
      .and_raise(Google::Apis::ClientError.new("Package not found: #{package}", status_code: 404))

    result = service.fetch(package)

    expect(result.code).to eq(:package_not_found)
    expect(result.message).to include(package)
  end

  it 'maps a 403 to access_denied' do
    allow(client).to receive(:insert_edit)
      .and_raise(Google::Apis::ClientError.new('forbidden', status_code: 403))

    expect(service.fetch(package).code).to eq(:access_denied)
  end

  it 'maps an authorization error to auth_failed' do
    allow(client).to receive(:insert_edit)
      .and_raise(Google::Apis::AuthorizationError.new('bad key'))

    expect(service.fetch(package).code).to eq(:auth_failed)
  end

  it 'reports an unexpected error as :error rather than raising' do
    allow(client).to receive(:insert_edit).and_raise(RuntimeError, 'kaboom')

    result = service.fetch(package)

    expect(result.code).to eq(:error)
    expect(result.message).to include('kaboom')
  end

  it 'stays ok when discarding the edit fails' do
    allow(client).to receive(:insert_edit).and_return(double(id: 'edit-1'))
    allow(client).to receive(:list_edit_listings).and_return(double(listings: [listing(language: 'en-US', title: 'A')]))
    allow(client).to receive(:list_edit_tracks).and_return(double(tracks: []))
    allow(client).to receive(:delete_edit).and_raise(StandardError, 'boom')

    result = service.fetch(package)

    expect(result).to be_ok
    expect(result.listings.first.title).to eq('A')
  end

  describe '#fetch_reviews' do
    let(:review_client) { double('AndroidPublisherService') }

    before { allow(service).to receive(:build_client).and_return(review_client) }

    it 'reports no_package_name without calling Google when the package is blank' do
      expect(service).not_to receive(:build_client)

      expect(service.fetch_reviews('  ').code).to eq(:no_package_name)
    end

    it 'reports not_configured when there is no credential' do
      expect(described_class.new(credential: nil).fetch_reviews(package).code).to eq(:not_configured)
    end

    it 'flattens Review -> Comment -> UserComment, keeping the developer reply' do
      user = double('UserComment', star_rating: 5, text: 'wonderful', original_text: nil,
                                   reviewer_language: 'en', device: 'Pixel', app_version_name: '1.2',
                                   thumbs_up_count: 3, thumbs_down_count: 0,
                                   last_modified: double(seconds: 1_700_000_000))
      developer = double('DeveloperComment', text: 'thanks!', last_modified: double(seconds: 1_700_100_000))
      review = double('Review', review_id: 'r1', author_name: 'Ada',
                      comments: [double(user_comment: user, developer_comment: developer)])
      allow(review_client).to receive(:list_reviews)
        .with(package, max_results: described_class::REVIEWS_PAGE_SIZE, translation_language: nil)
        .and_return(double(reviews: [review]))

      result = service.fetch_reviews(package)

      expect(result).to be_ok
      expect(result.package_name).to eq(package)
      info = result.reviews.first
      expect(info.review_id).to eq('r1')
      expect(info.author_name).to eq('Ada')
      expect(info.rating).to eq(5)
      expect(info.text).to eq('wonderful')
      expect(info.developer_reply).to eq('thanks!')
      expect(info.thumbs_up).to eq(3)
      expect(info.last_modified).to eq(Time.zone.at(1_700_000_000).to_date)
      expect(info.replied_at).to eq(Time.zone.at(1_700_100_000).to_date)
    end

    it 'falls back to original_text and reports no reply' do
      user = double('UserComment', star_rating: 3, text: nil, original_text: 'original',
                                   reviewer_language: nil, device: nil, app_version_name: nil,
                                   thumbs_up_count: nil, thumbs_down_count: nil, last_modified: nil)
      review = double('Review', review_id: 'r2', author_name: 'Bo',
                      comments: [double(user_comment: user, developer_comment: nil)])
      allow(review_client).to receive(:list_reviews).and_return(double(reviews: [review]))

      info = service.fetch_reviews(package).reviews.first

      expect(info.text).to eq('original')
      expect(info.developer_reply).to be_nil
      expect(info.last_modified).to be_nil
    end

    it 'passes a translation language through to Play when given one' do
      allow(review_client).to receive(:list_reviews)
        .with(package, max_results: anything, translation_language: 'en')
        .and_return(double(reviews: []))

      expect(service.fetch_reviews(package, translation_language: 'en')).to be_ok
    end

    it 'maps Play errors to Result codes rather than raising' do
      allow(review_client).to receive(:list_reviews)
        .and_raise(Google::Apis::ClientError.new('nope', status_code: 404))
      expect(service.fetch_reviews(package).code).to eq(:package_not_found)

      allow(review_client).to receive(:list_reviews)
        .and_raise(Google::Apis::AuthorizationError.new('bad key'))
      expect(service.fetch_reviews(package).code).to eq(:auth_failed)
    end
  end

  describe '#fetch_vitals' do
    let(:reporting_client) { double('PlaydeveloperreportingService') }

    before { allow(service).to receive(:build_reporting_client).and_return(reporting_client) }

    def row(kind:, day:, rate: nil, users: nil)
      metrics = []
      metrics << double(metric: kind, decimal_value: double(value: rate)) unless rate.nil?
      metrics << double(metric: 'distinctUsers', decimal_value: double(value: users)) unless users.nil?
      double(start_time: double(year: 2026, month: 10, day: day), aggregation_period: 'DAILY', metrics: metrics)
    end

    it 'reports no_package_name without calling Google when the package is blank' do
      expect(service).not_to receive(:build_reporting_client)

      expect(service.fetch_vitals('  ').code).to eq(:no_package_name)
    end

    it 'reports not_configured when there is no credential' do
      expect(described_class.new(credential: nil).fetch_vitals(package).code).to eq(:not_configured)
    end

    it 'reads crash, ANR, slow rendering and error count, keeping the latest interval per kind' do
      allow(reporting_client).to receive(:query_vital_crashrate).and_return(double(rows: [
        row(kind: 'crashRate', day: 8, rate: '0.42', users: '1234'),
        row(kind: 'crashRate', day: 9, rate: '0.55')
      ]))
      allow(reporting_client).to receive(:query_vital_anrrate).and_return(double(rows: [
        row(kind: 'anrRate', day: 9, rate: '0.10')
      ]))
      allow(reporting_client).to receive(:query_vital_slowrenderingrate).and_return(double(rows: [
        row(kind: 'slowRenderingRate', day: 9, rate: '12.5')
      ]))
      allow(reporting_client).to receive(:query_vital_error_count).and_return(double(rows: [
        row(kind: 'errorReportCount', day: 9, rate: '987', users: '4321')
      ]))

      result = service.fetch_vitals(package)

      expect(result).to be_ok
      expect(result.vitals.size).to eq(5)
      expect(result.crash.start_time).to eq('2026-10-09')
      expect(result.crash.value).to eq('0.55')
      expect(result.anr.start_time).to eq('2026-10-09')
      expect(result.anr.value).to eq('0.10')
      expect(result.slow_rendering.value).to eq('12.5')
      expect(result.error_count.value).to eq('987')
      expect(result.error_count.user_count).to eq('4321')
      expect(result.vitals.find { |v| v.start_time == '2026-10-08' }.user_count).to eq('1234')
    end

    it 'asks for the right metric-set resource and metric name per feature' do
      allow(reporting_client).to receive(:query_vital_crashrate).and_return(double(rows: []))
      allow(reporting_client).to receive(:query_vital_anrrate).and_return(double(rows: []))
      allow(reporting_client).to receive(:query_vital_slowrenderingrate).and_return(double(rows: []))
      allow(reporting_client).to receive(:query_vital_error_count).and_return(double(rows: []))

      service.fetch_vitals(package)

      expect(reporting_client).to have_received(:query_vital_crashrate)
        .with("apps/#{package}/crashRateMetricSet", have_attributes(metrics: %w[crashRate distinctUsers]))
      expect(reporting_client).to have_received(:query_vital_slowrenderingrate)
        .with("apps/#{package}/slowRenderingRateMetricSet", have_attributes(metrics: %w[slowRenderingRate distinctUsers]))
      expect(reporting_client).to have_received(:query_vital_error_count)
        .with("apps/#{package}/errorCountMetricSet", have_attributes(metrics: %w[errorReportCount distinctUsers]))
    end

    it 'leaves a rate nil when Play measured no datapoint (never 0)' do
      allow(reporting_client).to receive(:query_vital_crashrate)
        .and_return(double(rows: [row(kind: 'crashRate', day: 9)]))
      allow(reporting_client).to receive(:query_vital_anrrate).and_return(double(rows: []))
      allow(reporting_client).to receive(:query_vital_slowrenderingrate).and_return(double(rows: []))
      allow(reporting_client).to receive(:query_vital_error_count)
        .and_return(double(rows: [row(kind: 'errorReportCount', day: 9)]))

      result = service.fetch_vitals(package)

      expect(result.crash.value).to be_nil
      expect(result.anr).to be_nil
      expect(result.slow_rendering).to be_nil
      expect(result.error_count.value).to be_nil
    end

    it 'maps Play errors to Result codes rather than raising' do
      allow(reporting_client).to receive(:query_vital_crashrate)
        .and_raise(Google::Apis::ClientError.new('nope', status_code: 403))

      expect(service.fetch_vitals(package).code).to eq(:access_denied)
    end
  end
end
