# frozen_string_literal: true

# Z-P16 (Play Console parity, scale/reach): the reports surface. Play's analytics lives inside the Console;
# a self-hosted instance lets the operator run the reporting stack instead of shipping one. This page is the
# single, honest place that says what is configured: which self-hostable site-view tool is live (Umami,
# Plausible, Matomo), and links out to the operator-run BI tool over Zealot's own Postgres (Metabase or
# Superset). Zealot never proxies those tools or holds their credentials — the links are the operator's own.
#
# Admin-only (the admin namespace is gated on `user.admin?` in config/routes.rb). Read-only: it configures
# nothing, it reports what the environment already set.
class Admin::ReportsController < ApplicationController
  def index
    @title = t('admin.reports.index.title')
  end
end
