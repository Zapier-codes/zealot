# frozen_string_literal: true

# Z-P10 / Task 50: who may see the revenue report. The report is always scoped to the signed-in user's own
# publisher profile (RevenuesController), so the question is only "may this signed-in person see revenue at
# all" — any authenticated user may, and a signed-out one may not (the controller authenticates first).
class RevenuePolicy < ApplicationPolicy
  def show?
    user_signed_in?
  end
end
