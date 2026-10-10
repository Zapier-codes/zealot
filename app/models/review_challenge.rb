# frozen_string_literal: true

# Z-P9 (principle 2): a one-time proof-of-work challenge, the shape ALTCHA issues. The server returns a
# `nonce`, a `salt` and a `cost`; the client finds a `number` such that SHA-256(salt + number + nonce) begins
# with `cost` zero nibbles, and sends the number back with the review. Because the puzzle costs a little work
# and each challenge is single-use, a script cannot post thousands of reviews for free -- the same reason
# ALTCHA exists, without the tracking a captcha service brings.
#
# A challenge exists to bound work, not to identify anyone. It carries no cookie and no address: the
# network-level limit is a salted, daily-rotating digest (`ip_digest`) so the same network can be counted
# without the address ever being stored.
class ReviewChallenge < ApplicationRecord
  include TenantOwned

  # How long a challenge stays valid once issued.
  TTL = 10.minutes
  DEFAULT_COST = 3 # 3 leading zero nibbles (a ~1/4096 hit per try) -- a beat of work, not a wall.

  validates :nonce, presence: true, uniqueness: true
  validates :salt, presence: true
  validates :cost, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 8 }

  scope :live, -> { where('expires_at > ?', Time.current) }

  # The string a client must hash to solve the challenge. Public because the browser and the client hash it
  # themselves; it is not a secret and encodes nothing about the person.
  def solution_payload(number)
    "#{salt}#{number}#{nonce}"
  end

  # A solution is correct iff the hash of the payload has at least `cost` leading zero hex nibbles. Verified
  # on the raw number so a client cannot send a precomputed digest instead of the work.
  def solution_valid?(number)
    return false if number.blank?

    hex = OpenSSL::Digest::SHA256.hexdigest(solution_payload(number.to_s))
    hex.start_with?('0' * cost)
  end

  # Issue a fresh challenge. Returns the record.
  def self.issue!(remote_ip:, tenant: nil, cost: DEFAULT_COST)
    create!(nonce: SecureRandom.urlsafe_base64(16),
            salt: SecureRandom.urlsafe_base64(12),
            cost: cost,
            ip_digest: ip_digest_for(remote_ip),
            expires_at: TTL.from_now,
            tenant: tenant)
  end

  # A salted, daily-rotating digest of an address. Two requests from one network on the same day share it;
  # after midnight (server zone) it changes, so nothing links a network across days. The salt is stable per
  # day so it cannot be used as a rainbow-table oracle for a small address space.
  def self.ip_digest_for(remote_ip)
    return nil if remote_ip.blank?

    day = Date.current.to_s
    salt = OpenSSL::Digest::SHA256.hexdigest("zealot-review-ip:#{day}")
    OpenSSL::HMAC.hexdigest('SHA256', salt, remote_ip.to_s)
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # Mark solved exactly once, atomically, so two racing requests cannot both consume the same token. Returns
  # true for the request that won, false otherwise (including an already-expired challenge).
  def consume!
    return false if expired?

    affected = self.class.where(id: id, solved_at: nil).update_all(solved_at: Time.current, updated_at: Time.current)
    affected == 1
  end
end
