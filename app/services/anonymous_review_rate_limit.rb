# frozen_string_literal: true

# Z-P9 (principle 2): rate limits for the anonymous review path, counted from what is already stored so there
# is no separate counter table to keep in sync.
#
# Two limits, because they stop different abuse:
#   * per reviewer key -- one person cannot flood by solving one proof-of-work and reusing the key. This is a
#     wide limit (the key is one device); it stops the sustained script, not a keen reviewer.
#   * per network -- one network's total challenges are bounded, using the daily-rotating `ip_digest` on the
#     challenges. The address is never stored, so this limit cannot become a tracking device; it is only ever
#     compared as "how many challenges did this digest ask for today".
#
# A limit is a refusal with a reason, never a silent drop: the caller turns it into a 429 with a `Retry-After`.
class AnonymousReviewRateLimit
  KEY_WINDOW = 1.hour
  KEY_MAX = 10        # reviews a single device key may write in an hour
  NETWORK_WINDOW = 1.hour
  NETWORK_MAX = 30    # challenges one network digest may request in an hour

  Result = Struct.new(:allowed, :reason, :retry_after, keyword_init: true) do
    def allowed? = !!allowed
  end

  # Checked before issuing a challenge (the cheaper of the two write points) so a flood is bounded at the
  # door, and again is not needed on submit -- a challenge can only be consumed once.
  def challenge_allowed?(ip_digest:)
    return Result.new(allowed: true) if ip_digest.blank?

    recent = ReviewChallenge.where(ip_digest: ip_digest).where('created_at > ?', NETWORK_WINDOW.ago)
    if recent.count >= NETWORK_MAX
      oldest = recent.order(:created_at).first
      Result.new(allowed: false, reason: 'network_rate_limited',
                 retry_after: ((oldest.created_at + NETWORK_WINDOW) - Time.current).ceil)
    else
      Result.new(allowed: true)
    end
  end

  # Checked before a review is written, so one key cannot post more than KEY_MAX an hour even with fresh
  # challenges.
  def key_allowed?(reviewer_key:)
    return Result.new(allowed: true) if reviewer_key.nil?

    recent = reviewer_key.anonymous_reviews.where('updated_at > ?', KEY_WINDOW.ago)
    return Result.new(allowed: true) if recent.count < KEY_MAX

    oldest = recent.order(:updated_at).first
    Result.new(allowed: false, reason: 'key_rate_limited',
               retry_after: ((oldest.updated_at + KEY_WINDOW) - Time.current).ceil)
  end
end
