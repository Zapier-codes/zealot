# frozen_string_literal: true

# Task 42h: remember that Zealot itself suspended an app because its maintenance fee lapsed, so that a later
# successful maintenance payment brings back only those apps (an app suspended for another reason, such as an
# unverified company, must not come back just because it paid). Additive; NULL means not lapsed.
class AddLapsedAtToAppMaintenanceBillings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_maintenance_billings, :lapsed_at, :datetime
  end
end
