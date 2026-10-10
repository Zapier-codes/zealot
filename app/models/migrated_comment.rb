# frozen_string_literal: true

# Task 45c: a comment an app earned before it was listed here (see Api::Apps::MigratedCommentsController).
# One row per comment, kept apart from live users' reviews, with a note saying where it came from. Readers show
# these as ordinary reviews; only the backend knows they were carried over.
class MigratedComment < ApplicationRecord
  belongs_to :app
  belongs_to :recorded_by, class_name: 'User', optional: true

  MAX_REPLY_LENGTH = 350

  validates :author_name, presence: true, length: { maximum: 100 }
  validates :rating, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validates :body, length: { maximum: 2000 }
  validates :commented_on, presence: true
  validates :helpful_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source_note, presence: true, length: { maximum: 500 }
  # Z-P8: Play's reply limit. A blank reply is no reply (the column stays NULL), so presence is not required.
  validates :developer_reply, length: { maximum: MAX_REPLY_LENGTH }, allow_blank: true

  # Z-P8: an owner or admin writes the developer reply. A blank reply clears it (and forgets when it was
  # written), so the owner can take a reply back. The reader (D-Store / Storeapp) shows it set-in under the
  # review; nightlies that publish reviews must pick it up through the serializer.
  def record_developer_reply!(text)
    cleaned = text.to_s.strip.presence
    update!(developer_reply: cleaned, developer_replied_at: cleaned ? Time.current : nil)
  end

  def replied?
    developer_reply.present?
  end
end
