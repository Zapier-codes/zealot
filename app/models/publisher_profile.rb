# frozen_string_literal: true

# Task 25: how a user publishes on our own stores — Individual or Company —
# and the public name / contact details the store needs. One per user; an app
# is submitted under its owner's profile (App#publisher_profile).
#
# Company verification (KYB: registration details, D-U-N-S, review, the
# 2-month deadline) is a later slice and will hang off this record.
class PublisherProfile < ApplicationRecord
  DISPLAY_NAME_MAX_LENGTH = 60

  belongs_to :user
  has_many :apps, dependent: :nullify

  enum :kind, { individual: 'individual', company: 'company' }, validate: true

  before_validation :normalize_text_fields

  validates :display_name, presence: true, length: { maximum: DISPLAY_NAME_MAX_LENGTH }
  validates :legal_name, presence: true, length: { maximum: 120 }
  validates :country, presence: true, length: { maximum: 80 }
  validates :contact_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validate :kind_locked_once_live, on: :update

  private

  # Switching Individual <-> Company changes what the publisher owes us
  # (verification), so it can't be flipped while one of their apps is already
  # live on the store.
  def kind_locked_once_live
    return unless kind_changed? && apps.listing_live.exists?

    errors.add(:kind, :locked_once_live)
  end

  def normalize_text_fields
    %i[display_name legal_name country contact_email].each do |attr|
      self[attr] = self[attr].to_s.gsub(/[[:cntrl:]]/, ' ').squish.presence
    end
  end
end
