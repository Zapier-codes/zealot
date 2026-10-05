import os
import re

os.chdir(os.path.expanduser('~/zealot'))

# 1. Remove requires_payment? from release_upload_finisher.rb
f = 'app/services/release_upload_finisher.rb'
s = open(f).read()

# Remove the call in release_attributes
s = s.replace("    attributes[:status] = 'available' unless hold_requested?(row) || requires_payment?(row)\n", "    attributes[:status] = 'available' unless hold_requested?(row)\n")

# Remove the method definition
s = s.replace("""
  # Task 40o: Manual dashboard uploads require payment before becoming available.
  def requires_payment?(row)
    row.form_options['source'] == 'web'
  end
""", "")

open(f, 'w').write(s)

# 2. Remove the payment gating specs from release_upload_finisher_spec.rb
f = 'spec/services/release_upload_finisher_spec.rb'
s = open(f).read()

# Remove the describe block for payment gating
s = re.sub(r"  # Task 40o: The rejection rule is removed\. CI unconditionally injects and signs all uploads\.\n  # Task 40o: Manual dashboard uploads require payment before becoming available\.\n  describe 'payment gating for manual uploads' do.*?  end\n\n", "", s, flags=re.DOTALL)

open(f, 'w').write(s)

# 3. Update handover.md
f = 'handover.md'
s = open(f).read()
s += "\n\n## Task 40o (cont): Removed per-upload payment gate\n\n- Removed `requires_payment?` from `ReleaseUploadFinisher`.\n- Manual dashboard uploads and API uploads are both accepted and made `available` immediately after CI processes them.\n- The catalog index serializer's `listing_live` scope ensures uploads for unpaid apps still do not appear in the public store until the account/app listing fee is paid.\n"
open(f, 'w').write(s)

print("Payment gate removed successfully.")
