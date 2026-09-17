# frozen_string_literal: true

# Play Store publish-approval queue (task #11). Acts on Release records
# that have play_store_target set and are awaiting approval — this is
# bookkeeping only, see handover.md's "Scope, stated plainly": nothing here
# calls the actual Play Developer API (task #7) and nothing here ever
# removes a release from our own internal distribution, approved or not.
class Admin::PlayApprovalsController < ApplicationController
  before_action :set_release, only: %i[ approve reject ]

  # GET /admin/play_approvals
  def index
    @releases = Release.awaiting_play_approval.includes(channel: { scheme: :app }).order(play_approval_requested_at: :asc)
    authorize @releases if @releases.present?

    # Task #7: separate from the approval queue above — these are releases
    # already approved (or rejected) whose actual Play Developer API publish
    # attempt is worth showing status/error for. See Release#play_publish_status.
    @published_releases = Release.play_publish_tracked.includes(channel: { scheme: :app }).order(updated_at: :desc)
    authorize @published_releases if @published_releases.present?
  end

  # PUT /admin/play_approvals/1/approve
  def approve
    @release.approve_play_publish!(current_user)
    notice = t('admin.play_approvals.messages.approved', name: @release.app_name)
    redirect_to admin_play_approvals_path, notice: notice
  end

  # PUT /admin/play_approvals/1/reject
  def reject
    @release.reject_play_publish!(current_user)
    notice = t('admin.play_approvals.messages.rejected', name: @release.app_name)
    redirect_to admin_play_approvals_path, notice: notice
  end

  private

  def set_release
    @release = Release.find(params[:id])
    authorize @release, "#{action_name}_play_publish?"
  end
end
