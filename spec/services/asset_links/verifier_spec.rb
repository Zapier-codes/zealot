# frozen_string_literal: true

require 'rails_helper'

# Z-P22: the assetlinks.json checker. Google is stubbed through Faraday's test adapter, so no request
# leaves the process. Every state is pinned: verified, a file that does not name this app, a non-200, a
# body that is not the expected JSON array, and a link with no certificate to check against.
RSpec.describe AssetLinks::Verifier do
  let(:fingerprint) { 'AA:BB:CC:DD:EE:FF' }
  let(:other_fingerprint) { '11:22:33:44:55:66' }
  let(:package_name) { 'com.example.app' }

  def build(host: 'example.com', sha256: fingerprint, package: package_name, body: nil, status: 200)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/.well-known/assetlinks.json') do
        [status, { 'Content-Type' => 'application/json' }, body.to_s]
      end
    end
    described_class.call(host: host, package_name: package, sha256: sha256, adapter: [:test, stubs])
  end

  def statement(package:, fingerprints:, relation: described_class::RELATION, namespace: 'android_app')
    {
      relation: [relation],
      target: {
        namespace: namespace,
        package_name: package,
        sha256_cert_fingerprints: fingerprints
      }
    }
  end

  describe 'host validation' do
    it 'refuses a blank host without a request' do
      result = build(host: '')
      expect(result.state).to eq(described_class::STATE_INVALID)
      expect(result.http_status).to be_nil
    end

    it 'refuses a bare word that is not a hostname' do
      expect(build(host: 'example').state).to eq(described_class::STATE_INVALID)
    end

    it 'refuses an IP literal' do
      expect(build(host: '192.168.0.1').state).to eq(described_class::STATE_INVALID)
    end

    it 'accepts a normal https host and strips the scheme and path' do
      body = JSON.generate([statement(package: package_name, fingerprints: [fingerprint])])
      expect(build(host: 'https://example.com/path', body: body).state).to eq(described_class::STATE_VERIFIED)
    end
  end

  describe 'association' do
    it 'verifies when a statement names the package and the certificate' do
      body = JSON.generate([statement(package: package_name, fingerprints: [other_fingerprint, fingerprint])])
      result = build(body: body)
      expect(result.state).to eq(described_class::STATE_VERIFIED)
      expect(result.verified?).to be(true)
    end

    it 'does not verify when the certificate differs' do
      body = JSON.generate([statement(package: package_name, fingerprints: [other_fingerprint])])
      expect(build(body: body).state).to eq(described_class::STATE_NOT_ASSOCIATED)
    end

    it 'does not verify when the package differs' do
      body = JSON.generate([statement(package: 'com.other.app', fingerprints: [fingerprint])])
      expect(build(body: body).state).to eq(described_class::STATE_NOT_ASSOCIATED)
    end

    it 'does not verify when the relation is not the App Link relation' do
      body = JSON.generate([statement(package: package_name, fingerprints: [fingerprint], relation: 'delegate_permission/common.get_login_creds')])
      expect(build(body: body).state).to eq(described_class::STATE_NOT_ASSOCIATED)
    end

    it 'does not verify when the namespace is not android_app' do
      body = JSON.generate([statement(package: package_name, fingerprints: [fingerprint], namespace: 'web')])
      expect(build(body: body).state).to eq(described_class::STATE_NOT_ASSOCIATED)
    end

    it 'matches the fingerprint case-insensitively' do
      body = JSON.generate([statement(package: package_name, fingerprints: [fingerprint.downcase])])
      expect(build(body: body).state).to eq(described_class::STATE_VERIFIED)
    end
  end

  describe 'failure states' do
    it 'reports unreachable on a non-200' do
      result = build(status: 404, body: 'not found')
      expect(result.state).to eq(described_class::STATE_UNREACHABLE)
      expect(result.http_status).to eq(404)
    end

    it 'reports invalid when the body is not a JSON array' do
      expect(build(body: '{"not":"an array"}').state).to eq(described_class::STATE_INVALID)
    end

    it 'reports invalid when the body is not JSON at all' do
      expect(build(body: '<html>').state).to eq(described_class::STATE_INVALID)
    end

    it 'reports no_certificate when there is no certificate to check' do
      result = build(sha256: '')
      expect(result.state).to eq(described_class::STATE_NO_CERTIFICATE)
    end
  end
end
