# frozen_string_literal: true

# Task 45c: a comment an app earned before it was listed here (see Api::Apps::MigratedCommentsController).
# One row per comment, kept apart from live users' reviews, with a note saying where it came from. Readers show
# these as ordinary reviews; only the backend knows they were carried over.
class MigratedComment < ApplicationRecord
  belongs_to :app
  belongs_to :recorded_by, class_name: 'User', optional: true

  validates :author_name, presence: true, length: { maximum: 100 }
  validates :rating, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validates :body, length: { maximum: 2000 }
  validates :commented_on, presence: true
  validates :helpful_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source_note, presence: true, length: { maximum: 500 }
end
