# frozen_string_literal: true

# Z-P10 / Task 50: who may arrange or cancel a payout. A payout is always scoped to the signed-in user's own
# publisher profile (PayoutsController#set_payout), so the record rule is only "signed in"; the ownership
# check is the scope, not this policy.
class PayoutPolicy < ApplicationPolicy
  def create?
    user_signed_in?
  end

  def cancel?
    user_signed_in?
  end

  def refresh?
    user_signed_in?
  end
end
