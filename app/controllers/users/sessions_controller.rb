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

  # /admin (signed out) renders this same login page and marks the form, so the
  # controller knows the login came in through the admin entry.
  def admin_entry?
    params[:admin_entry].to_s == '1'
  end

  # Admin entry lands in the admin area (admins only); everything else keeps
  # Devise's normal behaviour.
  def after_sign_in_path_for(resource)
    return admin_root_path if admin_entry? && resource.respond_to?(:admin?) && resource.admin?

    super
  end

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
  # Roles: everyone is created as a developer, except the single admin email
  # (User.admin_signup_email), which can only be created as admin through the
  # /admin entry. That email is never created on the normal login page (so
  # nobody can squat it as a developer), and no other email can ever become
  # admin here.
  #
  # Returns true only when it has already rendered a response (the new account
  # failed validation, e.g. password too short). In every other case it returns
  # false and normal Devise authentication continues — including right after a
  # successful registration, where it simply signs the new user in.
  #
  # Guard rails: an existing email is never touched (no promotion either), so a
  # wrong password for a known account can't overwrite or re-create anything.
  # Setting.registrations_enabled gates ordinary sign-ups; the admin entry is
  # not gated by it so the administrator can never be locked out.
  def register_unknown_user
    credentials = params.fetch(:user, {})
    email = credentials[:email].to_s.strip.downcase
    password = credentials[:password].to_s
    return false if email.blank? || password.blank? || User.exists?(['lower(email) = ?', email])

    role = role_for_new_registration(email)
    return false if role.nil?

    user = User.new(email: email, password: password, password_confirmation: password,
                    username: User.unique_username_for(email), role: role)
    user.skip_confirmation!
    return false if user.save

    self.resource = user
    @active_tab = 'normal'
    flash.now[:alert] = user.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
    true
  end

  # :admin, :developer, or nil (= do not create anything).
  def role_for_new_registration(email)
    is_admin_email = email == User.admin_signup_email

    if admin_entry?
      is_admin_email ? :admin : nil
    elsif is_admin_email
      nil
    else
      Setting.registrations_enabled ? :developer : nil
    end
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
