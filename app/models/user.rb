# frozen_string_literal: true

PROVIDERS = %i[feishu gitlab google_oauth2 ldap openid_connect github gitea].freeze

class User < ApplicationRecord
  include UserSettings
  include UserRoles

  extend UserOmniauth
  devise :database_authenticatable, :registerable, :confirmable, :rememberable, :trackable, 
         :validatable, :recoverable, :lockable, :magic_link_authenticatable, 
         :omniauthable, omniauth_providers: %i[feishu gitlab google_oauth2 ldap openid_connect github gitea].freeze

  enum :role, %i[member developer admin]
  enum :locale, enum_roles
  enum :appearance, enum_appearances
  enum :timezone, enum_timezones

  has_and_belongs_to_many :apps
  has_many :collaborators, dependent: :destroy
  has_many :metadatum, dependent: :destroy
  has_many :providers, class_name: 'UserProvider', dependent: :destroy

  scope :avaiables, -> (id) { where.not(id: id) }

  validates :username, presence: true
  validates :email, presence: true

  after_initialize :set_default_role, if: :new_record?
  after_initialize :set_user_default_settings, if: :new_record?
  after_initialize :generate_user_token, if: :new_record?

  # Picks a username for an account that was created straight from the login
  # form (email + password only): the email's local part, cleaned up, with a
  # numeric suffix when that name is already taken.
  def self.unique_username_for(email)
    base = email.to_s.split('@').first.to_s.gsub(/[^\w.\-]/, '')[0, 30].presence || 'user'
    candidate = base
    suffix = 1
    while exists?(username: candidate)
      suffix += 1
      candidate = "#{base}#{suffix}"
    end
    candidate
  end

  def create_app(**params)
    role_params = params.delete(:roles) || {}
    owner = params.delete(:owner) || false
    role = params.delete(:role) || Collaborator.roles[:member]

    ActiveRecord::Base.transaction do
      app = App.create(params)

      role_params[:user] = self
      role_params[:app] = app
      if owner
        role_params[:role] = Collaborator.roles[:admin]
        role_params[:owner] = true
      else
        role_params[:role] = role
        role_params[:owner] = false
      end

      Collaborator.create(role_params)

      app
    end
  end

  private

  def set_default_role
    self.role ||= Setting.preset_role || :member
  end

  def set_user_default_settings
    self.locale ||= Setting.site_locale
    self.appearance ||= Setting.site_appearance
    self.timezone ||= Setting.site_timezone
  end

  def generate_user_token
    self.token = Digest::MD5.hexdigest(SecureRandom.uuid)
  end

  # Email verification is disabled: never block sign in/sign up on
  # confirmation status. `confirmed_at` etc. are kept around (admin UI,
  # CreateAdminService) but no longer gate authentication.
  def confirmation_required?
    false
  end
end
