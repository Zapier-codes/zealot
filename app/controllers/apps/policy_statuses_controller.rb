# frozen_string_literal: true

# Z-P3 (Play Console parity): the policy-status page. Play surfaces a machine review verdict on the app — did
# the automated checks pass, flag something, or reject the build — before anyone looks. This page shows that
# verdict (recorded by Z-P2/Z-P4's AutomatedReviewJob) for every release of the app, with the reasons and the
# third-party SDKs found, newest first. Read-only: it reports, it never publishes or blocks.
class Apps::PolicyStatusesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/policy_status
  def show
    authorize @app, :show?

    @releases = @app.play_releases_scope
                    .where.not(automated_review_status: 'not_run')
                    .order(automated_reviewed_at: :desc, id: :desc)
                    .limit(50)
    @current = @app.play_releases_scope
                   .where.not(automated_review_verdict: nil)
                   .order(automated_reviewed_at: :desc, id: :desc).first
    @counts = @app.play_releases_scope
                  .where.not(automated_review_verdict: nil)
                  .group(:automated_review_verdict).count
    @title = t('apps.policy_statuses.show.title')
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end
end
