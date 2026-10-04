# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'

# Task 40i-a: checks the GitHub Actions OIDC token a workflow in the storage repo sends with its callback. This
# replaces the shared-secret stand-in of 40a for the new upload callbacks: there is no long-lived secret to leak
# or rotate. The workflow asks GitHub for an ID token whose audience is Zealot's URL; GitHub signs it (RS256)
# with a key published at the issuer's JWKS address; this class checks the signature and the claims below.
#
#   claims = GithubOidcVerifier.new(audience: 'https://zealot.example', repository: 'owner/storage',
#                                   workflow: 'read-upload.yml', ref: 'main').call(token)
#
# Checked, in this order, and any failure raises `Invalid` (one generic message for the caller, a reason in
# the log): size cap; three segments; header `alg` is exactly RS256 (never `none`, never HS*); a `kid` that
# names a published key; the RSA signature; `iss` is GitHub's issuer; `aud` contains our audience; `exp` and
# `nbf` with a one-minute leeway; `repository` equals the configured storage repo; `event_name` is
# `workflow_dispatch` (only Zealot dispatches these workflows); `job_workflow_ref` is the expected workflow
# file in that repo on the expected branch.
#
# The JWKS is cached for an hour. An unknown `kid` triggers one refetch, at most once a minute, so a stream of
# forged tokens cannot make this process hammer GitHub. No gem: the RSA key is built from the JWK's `n` and `e`
# with OpenSSL.
#
# Not verified against a real GitHub token from the sandbox this was written in (no Ruby, no network to GitHub):
# the spec signs tokens with a generated key and a fake JWKS.
class GithubOidcVerifier
  class Invalid < StandardError; end

  ISSUER = 'https://token.actions.githubusercontent.com'
  JWKS_URL = "#{ISSUER}/.well-known/jwks".freeze
  MAX_TOKEN_BYTES = 8 * 1024
  LEEWAY = 60
  JWKS_TTL = 1.hour
  REFETCH_EVERY = 1.minute
  JWKS_CACHE_KEY = 'github_oidc/jwks'
  REFETCH_GUARD_KEY = 'github_oidc/jwks_refetch_guard'

  # Reads GitHub's published keys. `call(refresh:)` answers an Array of JWK hashes; with `refresh: false` it may
  # answer from the cache, with `refresh: true` it goes to GitHub (but never more than once per REFETCH_EVERY).
  class JwksFetcher
    def initialize(transport: ReleaseStorage::GithubAdapter::HttpTransport.new, cache: Rails.cache, url: JWKS_URL)
      @transport = transport
      @cache = cache
      @url = url
    end

    def call(refresh: false)
      cached = @cache.read(JWKS_CACHE_KEY)
      return cached if cached && !refresh
      return fetch if cached.nil? || guard_open?

      cached
    end

    private

    def guard_open?
      @cache.write(REFETCH_GUARD_KEY, true, expires_in: REFETCH_EVERY, unless_exist: true)
    end

    def fetch
      response = @transport.call(:get, @url, headers: { 'Accept' => 'application/json',
                                                        'User-Agent' => 'zealot-oidc' })
      raise Invalid, "JWKS request answered HTTP #{response.status}" unless response.status == 200

      keys = JSON.parse(response.body.to_s).fetch('keys')
      raise Invalid, 'JWKS has no keys' unless keys.is_a?(Array) && keys.any?

      @cache.write(JWKS_CACHE_KEY, keys, expires_in: JWKS_TTL)
      keys
    rescue JSON::ParserError, KeyError, *ReleaseStorage::GithubAdapter::HttpTransport::NETWORK_ERRORS => e
      raise Invalid, "JWKS could not be read (#{e.class})"
    end
  end

  def initialize(audience:, repository:, workflow:, ref: 'main', jwks: JwksFetcher.new, now: Time.current)
    @audience = audience.to_s.chomp('/')
    @repository = repository.to_s
    @workflow = workflow.to_s
    @ref = ref.to_s
    @jwks = jwks
    @now = now.to_i
  end

  # @return [Hash] the verified claims
  # @raise [Invalid]
  def call(token)
    token = token.to_s
    raise Invalid, 'token missing' if token.empty?
    raise Invalid, 'token too large' if token.bytesize > MAX_TOKEN_BYTES

    header_b64, payload_b64, signature_b64 = split(token)
    header = decode_json(header_b64)
    verify_signature("#{header_b64}.#{payload_b64}", signature_b64, header)
    claims = decode_json(payload_b64)
    check_claims(claims)
    claims
  end

  private

  def split(token)
    parts = token.split('.', -1)
    raise Invalid, 'token is not three segments' unless parts.length == 3 && parts.none?(&:empty?)

    parts
  end

  def decode_json(segment)
    value = JSON.parse(Base64.urlsafe_decode64(segment))
    raise Invalid, 'segment is not an object' unless value.is_a?(Hash)

    value
  rescue JSON::ParserError, ArgumentError
    raise Invalid, 'segment is not valid base64url JSON'
  end

  def verify_signature(signing_input, signature_b64, header)
    raise Invalid, "unexpected alg #{header['alg'].inspect}" unless header['alg'] == 'RS256'

    kid = header['kid'].to_s
    raise Invalid, 'token has no kid' if kid.empty?

    jwk = find_key(kid)
    raise Invalid, 'unknown signing key' if jwk.nil?

    signature = Base64.urlsafe_decode64(signature_b64)
    ok = rsa_key(jwk).verify(OpenSSL::Digest.new('SHA256'), signature, signing_input)
    raise Invalid, 'bad signature' unless ok
  rescue ArgumentError, OpenSSL::OpenSSLError
    raise Invalid, 'signature could not be checked'
  end

  def find_key(kid)
    key = lookup(@jwks.call(refresh: false), kid)
    key || lookup(@jwks.call(refresh: true), kid)
  end

  def lookup(keys, kid)
    Array(keys).find { |jwk| jwk['kid'] == kid && jwk['kty'] == 'RSA' && jwk.fetch('use', 'sig') == 'sig' }
  end

  # RSA public key from a JWK: SubjectPublicKeyInfo built from the modulus and exponent.
  def rsa_key(jwk)
    modulus = OpenSSL::BN.new(Base64.urlsafe_decode64(jwk.fetch('n')), 2)
    exponent = OpenSSL::BN.new(Base64.urlsafe_decode64(jwk.fetch('e')), 2)
    public_key = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(modulus), OpenSSL::ASN1::Integer(exponent)])
    algorithm = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId('rsaEncryption'), OpenSSL::ASN1::Null(nil)])
    spki = OpenSSL::ASN1::Sequence([algorithm, OpenSSL::ASN1::BitString(public_key.to_der)])
    OpenSSL::PKey::RSA.new(spki.to_der)
  end

  def check_claims(claims)
    raise Invalid, 'wrong issuer' unless claims['iss'] == ISSUER
    raise Invalid, 'wrong audience' unless audiences(claims['aud']).include?(@audience)

    check_times(claims)
    raise Invalid, 'wrong repository' unless claims['repository'].to_s.casecmp?(@repository)
    raise Invalid, 'wrong event' unless claims['event_name'] == 'workflow_dispatch'

    expected = "#{@repository}/.github/workflows/#{@workflow}@refs/heads/#{@ref}"
    raise Invalid, 'wrong workflow' unless claims['job_workflow_ref'].to_s.casecmp?(expected)
  end

  def audiences(aud)
    Array(aud).map { |value| value.to_s.chomp('/') }
  end

  def check_times(claims)
    exp = claims['exp']
    raise Invalid, 'token has no exp' unless exp.is_a?(Integer)
    raise Invalid, 'token expired' if exp + LEEWAY < @now

    nbf = claims['nbf']
    raise Invalid, 'token not yet valid' if nbf.is_a?(Integer) && nbf - LEEWAY > @now
  end
end
