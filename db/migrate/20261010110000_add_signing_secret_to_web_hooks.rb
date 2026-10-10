# frozen_string_literal: true

# Z-P19 (Play Console parity, event-stream feed): sign the outgoing webhooks Zealot already sends. Today
# AppWebHookJob POSTs a JSON body with no way for the receiver to tell it came from Zealot and was not
# altered in flight. This adds a Standard Webhooks signing secret per web hook (encrypted at rest, like every
# other secret in the app); when one is set, every delivery carries `webhook-id`, `webhook-timestamp` and
# `webhook-signature` headers computed by Webhooks::StandardSignature. A receiver verifies them the same way
# it would verify a Svix/Svix-compatible sender. Existing hooks with no secret keep sending exactly as before.
class AddSigningSecretToWebHooks < ActiveRecord::Migration[8.1]
  def change
    add_column :web_hooks, :signing_secret, :text
    add_column :web_hooks, :signing_secret_set_at, :datetime
  end
end
