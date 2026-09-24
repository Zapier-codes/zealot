# frozen_string_literal: true

# Task 24: the name store visitors see as an app's publisher ("Published by …").
# Play always shows the organisation as owner; on our own stores a verified
# company can publish an app for somebody else under a different front-facing
# name. NULL = no alias (nothing extra is shown). Who may set it is decided by
# AppPolicy#set_publisher_alias?, not by this column.
class AddPublisherAliasToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :publisher_alias, :string
  end
end
