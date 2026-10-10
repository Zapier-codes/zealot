# frozen_string_literal: true

# Z-P8 (Play Console parity): reviews inbox + developer replies. Play lets an owner read every review an app
# has earned and reply once to the ones that ask for it; the reply is shown set-in under the review.
#
# Zealot's only reviews today are the carried-over rows in `migrated_comments` (Task 45c); when live user
# reviews arrive they will hang off the same inbox. This migration adds the developer reply (the text and when
# it was written) to those rows, so the inbox can hold it. A blank reply is stored as NULL -- the reader then
# has nothing to show, rather than an empty box.
class AddDeveloperReplyToMigratedComments < ActiveRecord::Migration[8.1]
  def change
    add_column :migrated_comments, :developer_reply, :text
    add_column :migrated_comments, :developer_replied_at, :datetime
  end
end
