# frozen_string_literal: true

# Task 25: who publishes on our own stores and whether an app is on the store.
#
# - publisher_profiles: one per user — Individual or Company, plus the public
#   name and the contact details the store needs. (Company verification /
#   KYB fields come in a later slice.)
# - apps.listing_status: draft -> awaiting_payment -> live (-> suspended);
#   apps.listed_at: first time it went live; apps.publisher_profile_id: the
#   profile the app was submitted under.
class CreatePublisherProfilesAndAppListing < ActiveRecord::Migration[7.1]
  def change
    create_table :publisher_profiles do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false, default: 'individual'
      t.string :display_name, null: false
      t.string :legal_name, null: false
      t.string :country, null: false
      t.string :contact_email, null: false
      t.timestamps
    end

    add_column :apps, :listing_status, :string, null: false, default: 'draft'
    add_column :apps, :listed_at, :datetime
    add_reference :apps, :publisher_profile, null: true, index: true,
                                             foreign_key: { on_delete: :nullify }
  end
end
