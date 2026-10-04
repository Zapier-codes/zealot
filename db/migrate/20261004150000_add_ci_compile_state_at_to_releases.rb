# frozen_string_literal: true

# Task 40g: when a release entered `queued` or `dispatched`, so a sweeper can tell a run that is still
# working from one that will never call back. Additive: NULL for every release, and the sweeper treats a
# NULL on an in-flight release as "start counting now" (see CiCompileSweeperJob), so nothing is failed
# early because of this column being new.
class AddCiCompileStateAtToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :ci_compile_state_at, :datetime
  end
end
