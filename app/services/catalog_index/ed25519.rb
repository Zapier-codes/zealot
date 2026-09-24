# frozen_string_literal: true

require 'base64'
require 'digest'
require 'openssl'

module CatalogIndex
  # Task 27b-ii: the Ed25519 primitives behind index signing, kept free of
  # Rails/ActiveRecord so they can be exercised on their own.
  #
  # Keys are stored/exchanged the portable way: the private key as PEM (what
  # OpenSSL writes and reads on every version), the public key as the raw
  # 32 bytes, base64 — what a JS verifier (WebCrypto, tweetnacl) wants. The raw
  # bytes are taken from the SubjectPublicKeyInfo DER rather than a
  # `raw_public_key` call, which older openssl gems don't have.
  module Ed25519
    # ASN.1 prefix of an Ed25519 SubjectPublicKeyInfo; the raw key follows it.
    SPKI_PREFIX = ['302a300506032b6570032100'].pack('H*').freeze
    RAW_LENGTH = 32

    module_function

    # @return [String] a new private key, PEM
    def generate_pem
      OpenSSL::PKey.generate_key('ED25519').private_to_pem
    end

    # @return [String] base64 of the raw 32-byte public key
    def public_key_b64(private_pem)
      der = OpenSSL::PKey.read(private_pem).public_to_der
      raise ArgumentError, 'not an Ed25519 key' unless der.start_with?(SPKI_PREFIX) && der.bytesize == SPKI_PREFIX.bytesize + RAW_LENGTH

      Base64.strict_encode64(der.byteslice(-RAW_LENGTH, RAW_LENGTH))
    end

    # A short, non-secret id for a public key (first 16 hex chars of its
    # SHA-256), so a reader can tell which key signed an index.
    def key_id(public_b64)
      Digest::SHA256.hexdigest(Base64.strict_decode64(public_b64))[0, 16]
    end

    # @return [String] base64 signature over the exact bytes given
    def sign(private_pem, data)
      Base64.strict_encode64(OpenSSL::PKey.read(private_pem).sign(nil, data))
    end

    # @return [Boolean] whether signature_b64 is a valid signature of exactly
    #   these bytes by this public key. Never raises on malformed input.
    def verify(public_b64, data, signature_b64)
      raw = Base64.strict_decode64(public_b64)
      return false unless raw.bytesize == RAW_LENGTH

      OpenSSL::PKey.read(SPKI_PREFIX + raw).verify(nil, Base64.strict_decode64(signature_b64), data)
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      false
    end
  end
end
