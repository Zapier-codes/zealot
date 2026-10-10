# frozen_string_literal: true

# Z-P9 (principle 2): verify an Android Key Attestation certificate chain, the proof behind the "verified
# install" mark and the device-bound reviewer key.
#
# An app that generates a key in the Android Keystore with an attestation challenge gets back a small X.509
# chain. The leaf certificate's public key is the key; its extension OID 1.3.6.1.4.1.11129.2.1.17
# (`KeyDescription`) says, in a signed blob, which security level made the key (Software / TEE / StrongBox)
# and what `attestationChallenge` was set when it was made. Checking that blob is what turns "a key" into
# "a key that a real Android device made, for this purpose, once".
#
# What this class checks, in order, and refuses to guess about:
#   1. the leaf carries the attestation extension and it decodes;
#   2. every certificate in the chain is signed by the next one (up to the last);
#   3. the last certificate chains to a trust anchor the operator pinned (no anchor -> `unsupported`);
#   4. the leaf's public key is byte-for-byte the key being registered (so the extension describes *this*
#      key, not some other);
#   5. the attestation challenge equals the nonce the server issued for this session (anti-replay);
#   6. the attestation security level is TEE or StrongBox (a Software level key is `failed`, never verified).
#
# A chain that fails any step returns a status: `failed` (proven wrong), `unsupported` (could not check,
# e.g. no pinned root), `verified` (every step passed). Never `verified` by default.
class AndroidKeyAttestation
  KEY_DESCRIPTION_OID = '1.3.6.1.4.1.11129.2.1.17'
  SECURITY_LEVELS = { 0 => 'software', 1 => 'trusted_environment', 2 => 'strong_box' }.freeze

  # The certificate a client presents, in leaf..root order (a PEM string or its DER bytes).
  Certificate = Struct.new(:x509, keyword_init: true) do
    def der = x509.to_der
    def public_key_der = x509.public_key.public_to_der
  end

  Result = Struct.new(:status, :verified, :security_level, :challenge, :reason, keyword_init: true)

  # `roots` are the pinned trust anchors. Empty (the default) means "no anchor configured", so nothing can be
  # proven and the result is `unsupported` -- the honest answer, and why the mark never appears until the
  # operator pins Google's hardware attestation root.
  def initialize(roots: self.class.configured_roots, clock: Time.current)
    @roots = Array(roots).compact.map { |pem| OpenSSL::X509::Certificate.new(pem) }
    @clock = clock
  end

  # The trust anchors, from `ZEALOT_ANDROID_ATTESTATION_ROOTS` (a path list of PEM files). Off unless set.
  def self.configured_roots
    paths = ENV['ZEALOT_ANDROID_ATTESTATION_ROOTS'].to_s.split(':').map(&:strip).reject(&:empty?)
    paths.filter_map { |p| File.read(p) if File.exist?(p) }
  end

  # Verify a presented chain against a `challenge` (the server nonce) and an expected `public_key_der`.
  # `chain_pems` is leaf..root. Returns a Result; never raises for a malformed chain.
  def verify(chain_pems:, challenge:, public_key_der:)
    certs = parse_chain(chain_pems)
    return Result.new(status: 'failed', verified: false, reason: 'unparseable_chain') if certs.empty?

    leaf = certs.first

    described = describe(leaf)
    return Result.new(status: 'failed', verified: false, reason: described.reason) unless described.security_level

    return Result.new(status: 'failed', verified: false, reason: 'public_key_mismatch',
                      security_level: described.security_level) unless same_key?(leaf, public_key_der)

    # Anti-replay: the challenge is fixed when the key is made, so it must be the nonce we just issued.
    return Result.new(status: 'failed', verified: false, reason: 'challenge_mismatch',
                      security_level: described.security_level) unless described.challenge.to_s == challenge.to_s

    # The internal chain must be intact regardless of trust.
    return Result.new(status: 'failed', verified: false, reason: 'broken_chain',
                      security_level: described.security_level) unless chain_intact?(certs)

    # Trust: the chain must reach a pinned anchor, else we simply cannot claim verification.
    if @roots.empty?
      return Result.new(status: 'unsupported', verified: false, reason: 'no_pinned_root',
                        security_level: described.security_level, challenge: described.challenge)
    end
    unless anchored?(certs)
      return Result.new(status: 'failed', verified: false, reason: 'untrusted_root',
                        security_level: described.security_level, challenge: described.challenge)
    end

    # A key made in the TEE or StrongBox is hardware-backed; a Software key is not, and is not "verified".
    if described.security_level == 'software'
      return Result.new(status: 'failed', verified: false, reason: 'software_security_level',
                        security_level: described.security_level, challenge: described.challenge)
    end

    Result.new(status: 'verified', verified: true, security_level: described.security_level,
               challenge: described.challenge, reason: nil)
  rescue OpenSSL::OpenSSLError, ArgumentError => e
    Result.new(status: 'failed', verified: false, reason: "error:#{e.class}")
  end

  private

  Described = Struct.new(:security_level, :challenge, :reason, keyword_init: true)

  def parse_chain(pems)
    Array(pems).map { |pem| OpenSSL::X509::Certificate.new(pem) }
  rescue OpenSSL::OpenSSLError
    []
  end

  # Pull `attestationSecurityLevel` and `attestationChallenge` out of the leaf's KeyDescription extension.
  def describe(leaf)
    ext = leaf.extensions.find { |e| e.oid == KEY_DESCRIPTION_OID }
    return Described.new(reason: 'no_attestation_extension') if ext.nil?

    asn1 = OpenSSL::ASN1.decode(ext.value_der)
    # `value_der` may carry the extnValue OCTET STRING's own wrapping around the KeyDescription SEQUENCE,
    # depending on how the extension was encoded; unwrap one layer when present so a real chain and this
    # decoder agree.
    asn1 = OpenSSL::ASN1.decode(asn1.value) if asn1.is_a?(OpenSSL::ASN1::OctetString)
    # KeyDescription ::= SEQUENCE { attestationVersion INTEGER, attestationSecurityLevel ENUMERATED,
    #   keymasterVersion INTEGER, keymasterSecurityLevel ENUMERATED, attestationChallenge OCTET_STRING, ... }
    seq = asn1.value
    level = seq[1].value.to_i
    challenge = seq[4].value
    Described.new(security_level: SECURITY_LEVELS[level] || "unknown(#{level})", challenge: challenge)
  rescue OpenSSL::ASN1::ASN1Error
    Described.new(reason: 'undecodable_extension')
  end

  def same_key?(leaf, public_key_der)
    return false if public_key_der.blank?

    leaf.public_key.public_to_der == public_key_der.to_s.b
  rescue OpenSSL::OpenSSLError
    false
  end

  # Each cert's signature must verify under the next cert's key.
  def chain_intact?(certs)
    certs.each_cons(2).all? { |child, parent| child.verify(parent.public_key) }
  end

  # The chain reaches a pinned anchor: either a presented cert equals an anchor, or a presented cert is issued
  # by an anchor (the common case -- the client does not send the root itself).
  def anchored?(certs)
    @roots.any? do |root|
      certs.any? { |c| c.to_der == root.to_der } ||
        certs.any? { |c| c.verify(root.public_key) && c.issuer.to_s == root.subject.to_s }
    end
  end
end
