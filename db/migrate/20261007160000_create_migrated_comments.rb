# frozen_string_literal: true

# Task 45c: comments an app earned before it was listed here (real history from a manual distribution), one row
# per comment so each stays individual, in a table of its own so they are never mixed with reviews written by
# live users here. The backend always knows which comments are carried over (this table); a reader shows them as
# ordinary reviews. A source note is required on every row, like the figures in Task 45a.
class CreateMigratedComments < ActiveRecord::Migration[8.1]
  def change
    create_table :migrated_comments do |t|
      t.references :app, null: false, foreign_key: { on_delete: :cascade }
      t.string :author_name, null: false
      t.integer :rating, null: false
      t.text :body
      t.date :commented_on, null: false
      t.integer :helpful_count, null: false, default: 0
      t.text :source_note, null: false
      t.references :recorded_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :migrated_comments, %i[app_id commented_on]
  end
end
