# frozen_string_literal: true

# Z-P9 (principle 2): the automated moderator on the anonymous review path. Play flags or removes reviews
# with links, contact details, shouting and repeated words; with no accounts to ban, the moderator is the
# only gate between "anyone can post" and "the storefront is readable". It runs on every submitted review and
# returns one of:
#
#   :publish   the review is fine, it goes live;
#   :pending   it might be spam -- it is stored but not public until an owner decides;
#   :reject    it is certainly spam -- it is stored as rejected and never publishes.
#
# The rules are deliberately conservative and explainable (no ML, no third-party service, no data leaving the
# box): each `flag` has a reason string, and the reasons are what an owner sees on a pending review. A review
# with no flags publishes; one hard flag rejects; several soft flags hold for a person.
class AnonymousReviewModerator
  # A URL or bare domain in the body is the strongest spam signal on a store review.
  LINK = %r{(https?://|www\.|\b[\w.-]+\.(com|net|org|io|ru|cn|xyz|top|info|biz)\b)}i
  # An email address or a long digit run (a phone number / contact handle).
  CONTACT = /([\w.+-]+@[\w-]+\.[\w.-]+)|\b\d{8,}\b/
  # A run of 8+ non-space characters with no lower-case letter is either a shout or gibberish.
  SHOUT = /\b[^a-z\s]{12,}\b/

  ALLOWED_EMAIL_DOMAINS = [].freeze # none: a review is not the place to leave an address

  # Number of distinct soft flags that turn "publish" into "hold for a person".
  SOFT_FLAG_HOLD_THRESHOLD = 2

  Result = Struct.new(:decision, :reason, keyword_init: true)

  def moderate(rating:, body:)
    flags = detached_flags(body)
    return Result.new(decision: :publish, reason: nil) if flags.empty?

    hard = flags & %i[link contact]
    return Result.new(decision: :reject, reason: hard.join(',')) if hard.any?

    if flags.size >= SOFT_FLAG_HOLD_THRESHOLD
      Result.new(decision: :pending, reason: flags.join(','))
    else
      Result.new(decision: :publish, reason: nil)
    end
  end

  private

  def detached_flags(body)
    text = body.to_s
    return [] if text.strip.empty?

    flags = []
    flags << :contact if text.match?(CONTACT)
    # A link is only spam when the address is not something the reviewer legitimately names; on a store
    # review there is no such case, so any URL is a link flag.
    flags << :link if text.match?(LINK)
    flags << :shout if text.match?(SHOUT)
    flags.uniq
  end
end
