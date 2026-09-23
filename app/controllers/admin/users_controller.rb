# frozen_string_literal: true

class Admin::UsersController < ApplicationController
  before_action :set_user, only: %i[edit update destroy lock unlock resend_confirmation]

  def index
    @users = User.all.order(id: :asc)
    authorize @users
  end

  def new
    @title = t('admin.users.new.title')
    @user = User.new
    authorize @user
  end

  def create
    @user = User.new_with_session(user_params, session)
    authorize @user

    # Industry-standard "invite" flow: an admin creating an account for
    # someone else shouldn't be inventing a password on that person's
    # behalf (the form deliberately doesn't mark password as required — see
    # _form.html.slim). Devise's :validatable still requires *some* value on
    # a new record (password_required? is true for !persisted?), so a blank
    # submission used to fail validation and the user was never created.
    #
    # Leaving it blank now creates the account with an unusable random
    # password and emails the new user a "set your password" link, sent
    # through the same Task 12/16 automated-email pipeline (Novu, with SMTP
    # as fallback) as every other Zealot email, rather than Devise's own
    # bare mailer. skip_confirmation! avoids a redundant separate "confirm
    # your email" message landing at the same time: clicking the
    # set-password link already proves the recipient controls the address.
    # If the admin does type a password, that's honored as-is and no invite
    # email is sent, since they've chosen to hand credentials over directly.
    invite = @user.password.blank?
    if invite
      @user.password = Devise.friendly_token[0, 20]
      @user.skip_confirmation!
    end

    # Any *other* validation failure (duplicate email, blank username, ...)
    # still needs to re-render the form with errors instead of crashing: see
    # the Task 21 (turbo-stream) note below — Turbo prefers a
    # text/vnd.turbo-stream.html Accept header on this modal-frame form, and
    # with no explicit format here Rails would try (and fail to find)
    # new.turbo_stream.slim before ever reaching this line's HTML render.
    return render :new, formats: [:html], status: :unprocessable_entity unless @user.save

    if invite
      set_password_url = edit_password_url(@user, reset_password_token: @user.set_reset_password_token)
      EmailNotifications.deliver_invite(@user, set_password_url: set_password_url) if EmailNotifications.enabled?
    end

    notice_key = invite ? 'invite' : 'create'
    flash.now[:notice] = t("activerecord.success.#{notice_key}", key: t('admin.users.title'))
    respond_to do |format|
      format.html { redirect_to admin_users_path }
      format.turbo_stream
    end
  end

  def edit
    authorize @user

    @title = @user.email
    @user.send(:generate_confirmation_token!) if @user.send(:confirmation_period_expired?)
  end

  def update
    authorize @user

    if helpers.default_admin_in_demo_mode?(@user)
      return redirect_to admin_users_path, alert: t('errors.messages.invaild_in_demo_mode')
    end

    # Skip password if not set
    params = user_params.dup
    params.delete(:password) if params[:password].blank?
    return render :edit, status: :unprocessable_entity unless @user.update(params)

    flash.now[:notice] = t('activerecord.success.update', key: t('admin.users.title'))
    respond_to do |format|
      format.html { redirect_to edit_admin_user_path(@user) }
      format.turbo_stream
    end
  end

  def destroy
    if helpers.default_admin_in_demo_mode?(@user)
      return redirect_to admin_users_path, alert: t('errors.messages.invaild_in_demo_mode')
    end
    authorize @user

    @user.destroy
    notice = t('activerecord.success.destroy', key: t('admin.users.title'))
    redirect_to admin_users_path, status: :see_other, notice: notice
  end

  def lock
    if @user.email == Setting.admin_email
      alert = t('errors.messages.cannot_lock_default_admin')
      flash.now[:alert] = alert
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
        format.turbo_stream { render :edit, status: :unprocessable_entity }
      end
      return
    end

    @user.lock_access!(send_instructions: false)
    flash.now[:notice] = t('.message', user: @user.username)
    respond_to do |format|
      format.html { redirect_to edit_admin_user_path(@user) }
      format.turbo_stream
    end
  end

  def unlock
    @user.unlock_access!
    flash.now[:notice] = t('.message', user: @user.username)
    respond_to do |format|
      format.html { redirect_to edit_admin_user_path(@user) }
      format.turbo_stream
    end
  end

  def resend_confirmation
    @user.send_confirmation_instructions
    flash.now[:notice] = t('.message', user: @user.username)
    # respond_to do |format|
    #   format.html { redirect_to admin_user_path(@user) }
    #   format.turbo_stream
    # end
  end

  private

  def set_user
    @user = User.find(params[:id])
    authorize @user
  end

  def user_params
    params.require(:user).permit(:username, :email, :password, :role, :locale, :appearance, :timezone)
  end
end
