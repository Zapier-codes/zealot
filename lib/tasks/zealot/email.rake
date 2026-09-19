# frozen_string_literal: true

# Task 12: operator tools for the automated emails.
#
#   rake zealot:email:test EMAIL=you@example.com
#   rake zealot:email:campaign SUBJECT="…" BODY="…"            (or BODY_FILE=path)
#   rake zealot:email:notice   SUBJECT="…" BODY="…" [APP=id]  (or BODY_FILE=path)
#   add DRY_RUN=1 to campaign / notice to only count recipients
namespace :zealot do
  namespace :email do
    desc 'Zealot | Send a test email to EMAIL (raises on SMTP errors)'
    task test: :environment do
      email = ENV['EMAIL'].to_s.strip
      abort 'EMAIL=you@example.com is required' if email.blank?

      user = User.find_by!(email: email)
      ActionMailer::Base.raise_delivery_errors = true
      NotificationMailer.notice(
        user, subject: "#{Setting.site_title} test email",
              body: 'If you can read this, outgoing email works.'
      ).deliver_now
      puts "Sent a test email to #{email}"
    end

    desc 'Zealot | Send a campaign to everyone who opted in to campaigns'
    task campaign: :environment do
      zealot_email_broadcast('campaigns')
    end

    desc 'Zealot | Send a maintenance / platform notice (APP=id limits it to one app)'
    task notice: :environment do
      zealot_email_broadcast('notices')
    end

    def zealot_email_broadcast(kind)
      subject = ENV['SUBJECT'].to_s.strip
      body = ENV['BODY_FILE'].present? ? File.read(ENV['BODY_FILE']) : ENV['BODY'].to_s
      abort 'SUBJECT and BODY (or BODY_FILE) are required' if subject.blank? || body.strip.blank?

      app = ENV['APP'].present? ? App.find(ENV['APP']) : nil
      recipients = EmailBroadcastJob.recipients(kind: kind, app_id: app&.id)

      if ActiveModel::Type::Boolean.new.cast(ENV['DRY_RUN'])
        puts "DRY RUN: #{recipients.count} recipient(s) would get #{kind} “#{subject}”"
        return
      end

      EmailBroadcastJob.perform_later(kind: kind, subject: subject, body: body, app_id: app&.id)
      puts "Queued #{kind} “#{subject}” for #{recipients.count} recipient(s)"
    end
  end
end
