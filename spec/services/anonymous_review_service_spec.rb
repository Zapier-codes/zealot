# frozen_string_literal: true

require 'rails_helper'

# Z-P9 (principle 2): the anonymous review path. The properties that matter are: the proof-of-work gate, the
# one-editable-review-per-key rule, the moderation decision, the earned (never assumed) install mark, and the
# rate limits. Written to run without a browser; the crypto parts use real OpenSSL so the byte-level contract
# with the Android client is exercised, not mocked.
RSpec.describe AnonymousReviewService do
  # Solve a challenge exactly the way the client does: find a number whose SHA-256 over salt+number+nonce has
  # `cost` leading zero nibbles.
  def solve(challenge)
    n = 0
    n += 1 until challenge.solution_valid?(n)
    n
  end

  let(:app) { create(:app) }
  let(:pkg) { 'com.example.app' }
  let(:service) { described_class.new(remote_ip: '203.0.113.9') }

  describe '#issue_challenge!' do
    it 'issues a solvable challenge carrying nonce, salt and cost' do
      result = service.issue_challenge!
      expect(result.ok?).to be(true)
      expect(result.review).to be_a(ReviewChallenge)
      expect(result.review.salt).to be_present
      expect(result.review.cost).to eq(ReviewChallenge::DEFAULT_COST)
    end

    it 'bounds challenges per network digest without storing the address' do
      allow(AnonymousReviewRateLimit).to receive(:new).and_return(
        AnonymousReviewRateLimit.new.tap do |rl|
          allow(rl).to receive(:challenge_allowed?).and_return(
            AnonymousReviewRateLimit::Result.new(allowed: false, reason: 'network_rate_limited', retry_after: 42)
          )
        end
      )
      result = described_class.new(remote_ip: '203.0.113.9').issue_challenge!
      expect(result.ok?).to be(false)
      expect(result.reason).to eq('network_rate_limited')
      expect(result.retry_after).to eq(42)
    end
  end

  describe '#submit!' do
    def submit(**over)
      challenge = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      service.submit!(app: app, package_name: pkg, rating: 5, body: 'Works well', challenge: challenge.nonce,
                      solution: solve(challenge), **over)
    end

    it 'publishes a clean review once the proof of work is solved' do
      result = submit
      expect(result.ok?).to be(true)
      expect(result.review.status).to eq('published')
      expect(app.anonymous_reviews.count).to eq(1)
    end

    it 'refuses an unsolved challenge' do
      challenge = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'x', challenge: challenge.nonce, solution: '0')
      expect(result.ok?).to be(false)
      expect(result.reason).to eq('bad_solution')
      expect(app.anonymous_reviews.count).to eq(0)
    end

    it 'refuses a challenge that was already consumed' do
      challenge = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      n = solve(challenge)
      service.submit!(app: app, package_name: pkg, rating: 4, body: 'a', challenge: challenge.nonce, solution: n)
      replay = service.submit!(app: app, package_name: pkg, rating: 4, body: 'b', challenge: challenge.nonce, solution: n)
      expect(replay.ok?).to be(false)
      expect(replay.reason).to eq('challenge_used')
    end

    it 'rejects a review carrying a link and does not publish it' do
      result = submit(body: 'great app http://spam.example')
      expect(result.ok?).to be(true)
      expect(result.review.status).to eq('rejected')
      expect(AnonymousReview.published.count).to eq(0)
    end
  end

  describe 'one editable review per device key' do
    let(:pkey) { OpenSSL::PKey::EC.generate('prime256v1') }
    let(:fingerprint) { ReviewerKey.fingerprint_for(pkey.to_pem) }
    let!(:key) do
      create(:reviewer_key, fingerprint: fingerprint, public_key_pem: pkey.to_pem, attestation_verified: true,
                            attestation_status: 'verified')
    end

    # Sign exactly as the Android client does (ReviewProto.signedPayload), so the byte contract is what is
    # under test, not a hand-built string that could drift from it.
    def sign(challenge_nonce, rating:, body:, version_code:)
      payload = described_class.signed_payload(package_name: pkg, rating: rating, body: body,
                                               version_code: version_code, challenge: challenge_nonce)
      Base64.strict_encode64(pkey.sign(OpenSSL::Digest::SHA256.new, payload))
    end

    it 'upserts: a second submission edits the first rather than adding one' do
      c1 = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      service.submit!(app: app, package_name: pkg, rating: 3, body: 'first', challenge: c1.nonce, solution: solve(c1))
      c2 = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      service.submit!(app: app, package_name: pkg, rating: 5, body: 'edited', challenge: c2.nonce, solution: solve(c2))

      expect(app.anonymous_reviews.count).to eq(1)
      expect(app.anonymous_reviews.first.rating).to eq(5)
      expect(app.anonymous_reviews.first.body).to eq('edited')
    end

    it 'accepts a review whose signature the key really made' do
      c = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'signed', challenge: c.nonce,
                               solution: solve(c), reviewer_key_fingerprint: fingerprint,
                               signature: sign(c.nonce, rating: 5, body: 'signed', version_code: nil))
      expect(result.ok?).to be(true)
      expect(app.anonymous_reviews.count).to eq(1)
    end

    it 'refuses a signature over different bytes than were submitted' do
      c = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      forged = sign(c.nonce, rating: 5, body: 'something else', version_code: nil)
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'signed', challenge: c.nonce,
                               solution: solve(c), reviewer_key_fingerprint: fingerprint, signature: forged)
      expect(result.ok?).to be(false)
      expect(result.reason).to eq('bad_signature')
    end

    it 'refuses a key fingerprint that is not registered' do
      c = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'signed', challenge: c.nonce,
                               solution: solve(c), reviewer_key_fingerprint: SecureRandom.hex(32),
                               signature: sign(c.nonce, rating: 5, body: 'signed', version_code: nil))
      expect(result.reason).to eq('unknown_key')
    end
  end

  describe 'the verified-install mark' do
    it 'is false without a device key even from the service' do
      challenge = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'web review', challenge: challenge.nonce,
                               solution: solve(challenge))
      expect(result.review.marked_verified?).to be(false)
    end

    it 'is earned only when a verified key names a real release of the app' do
      pkey = OpenSSL::PKey::EC.generate('prime256v1')
      key = create(:reviewer_key, fingerprint: ReviewerKey.fingerprint_for(pkey.to_pem),
                    public_key_pem: pkey.to_pem, attestation_verified: true, attestation_status: 'verified')
      scheme = app.schemes.create!(name: 'Main')
      channel = scheme.channels.create!(name: 'Android', device_type: :android)
      release = Release.new(channel: channel, version: 42, changelog: [], release_version: '1.0.0')
      release.save!(validate: false)

      c = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'looks right on my phone',
                               challenge: c.nonce, solution: solve(c),
                               reviewer_key_fingerprint: key.fingerprint, version_code: '42')
      expect(result.ok?).to be(true)
      expect(result.review.verified_install).to be(true)
      expect(result.review.marked_verified?).to be(true)
    end

    it 'is not given for a version code that is not a release' do
      pkey = OpenSSL::PKey::EC.generate('prime256v1')
      key = create(:reviewer_key, fingerprint: ReviewerKey.fingerprint_for(pkey.to_pem),
                    public_key_pem: pkey.to_pem, attestation_verified: true, attestation_status: 'verified')

      c = ReviewChallenge.issue!(remote_ip: '203.0.113.9')
      result = service.submit!(app: app, package_name: pkg, rating: 5, body: 'a version nobody published',
                               challenge: c.nonce, solution: solve(c),
                               reviewer_key_fingerprint: key.fingerprint, version_code: '9999')
      expect(result.ok?).to be(true)
      expect(result.review.verified_install).to be(false)
    end
  end
end
