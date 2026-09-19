# frozen_string_literal: true

# Task 15: everyone who registers is a developer, so existing `member` accounts
# are promoted to `developer` (roles: member=0, developer=1, admin=2 — see
# User.role). Admins are untouched, and only the global user role changes:
# per-app collaborator roles live in `collaborators` and are not affected.
#
# Plain SQL on purpose, so this keeps working if the User model changes later.
class PromoteMembersToDevelopers < ActiveRecord::Migration[8.1]
  def up
    execute 'UPDATE users SET role = 1 WHERE role = 0'
  end

  # Not reversible: after the promotion there is no record of which developers
  # used to be members, and demoting every developer would be wrong.
  def down; end
end
