# frozen_string_literal: true

class Users::SessionsController < Devise::Passwordless::SessionsController
  before_action :set_default_active_tab, only: %i[new create]
  
  def create
    return super if magic_link_request?

    # One page does both jobs: an unknown email + password registers a new
    # account, a known email logs in. Either way the login is remembered.
    return if register_unknown_user

    remember_login
    # For normal login, use the standard Devise create action
    Devise::SessionsController.instance_method(:create).bind(self).call
  end

  protected

  # Override to permit custom parameters
  def after_magic_link_sent_path_for(resource_or_scope)
    if magic_link_request?
      new_session_path(resource_or_scope)
    else
      after_sign_in_path_for(resource_or_scope)
    end
  end

  def magic_link_request?
    @magic_link_request ||= -> {
      type = params.require(:user).delete(:type)
      type == 'passwordless'
    }.call
  end

  private

  # Persistent login: the form has no "remember me" checkbox any more, so every
  # normal login is remembered (Devise `remember_for`, currently 1 year; the
  # remember cookie is cleared on sign out).
  def remember_login
    params.require(:user)[:remember_me] = '1'
  end

  # Registers the account when the submitted email is not known yet.
  #
  # Returns true only when it has already rendered a response (the new account
  # failed validation, e.g. password too short). In every other case it returns
  # false and normal Devise authentication continues — including right after a
  # successful registration, where it simply signs the new user in.
  #
  # Guard rails: Setting.registrations_enabled is the gate (off => unknown
  # emails just get the usual "invalid email or password" and nothing is
  # created), and an existing email is never touched, so a wrong password for a
  # known account can't overwrite or re-create anything.
  def register_unknown_user
    return false unless Setting.registrations_enabled

    credentials = params.fetch(:user, {})
    email = credentials[:email].to_s.strip.downcase
    password = credentials[:password].to_s
    return false if email.blank? || password.blank? || User.exists?(['lower(email) = ?', email])

    user = User.new(email: email, password: password, password_confirmation: password,
                    username: User.unique_username_for(email))
    user.skip_confirmation!
    return false if user.save

    self.resource = user
    @active_tab = 'normal'
    flash.now[:alert] = user.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
    true
  end

  def create_params
    if magic_link_request?
      resource_params.permit(:email, :remember_me)
    else
      resource_params.permit(:email, :password, :remember_me)
    end
  end

  def set_default_active_tab
    @active_tab = params[:tab].presence || 'normal'
  end
end
