# frozen_string_literal: true

require 'rails_helper'

# Task 37b-ii-t1: the Tenant record (fields per TenantConfig v1, Task 37a). Built with the
# `tenant` factory; needs Postgres (jsonb, check constraints, the domain-overlap query).
RSpec.describe Tenant do
  describe 'the factory' do
    it 'builds a valid tenant' do
      expect(build(:tenant)).to be_valid
    end
  end

  describe 'tenant_id' do
    it 'is refused when it is the reserved default tenant' do
      expect(build(:tenant, tenant_id: 'default')).not_to be_valid
    end

    it 'is lowercased and stripped before validation' do
      tenant = build(:tenant, tenant_id: '  Acme-Store ')
      expect(tenant).to be_valid
      expect(tenant.tenant_id).to eq('acme-store')
    end

    it 'rejects anything that is not a DNS label' do
      ['acme_store', '-acme', 'acme-', 'ac me', 'a' * 64, ''].each do |bad|
        expect(build(:tenant, tenant_id: bad)).not_to be_valid, "expected #{bad.inspect} to be invalid"
      end
    end

    it 'accepts a 63-character label and a single character' do
      expect(build(:tenant, tenant_id: 'a' * 63)).to be_valid
      expect(build(:tenant, tenant_id: 'a')).to be_valid
    end

    it 'must be unique' do
      create(:tenant, tenant_id: 'acme')
      expect(build(:tenant, tenant_id: 'acme')).not_to be_valid
    end

    it 'cannot be changed once the tenant exists' do
      tenant = create(:tenant, tenant_id: 'acme')
      # Depending on `raise_on_assign_to_attr_readonly`, the assignment either raises or the
      # validation refuses it; either way nothing is persisted.
      result = begin
        tenant.update(tenant_id: 'other')
      rescue ActiveRecord::ReadonlyAttributeError
        false
      end

      expect(result).to be(false)
      expect(tenant.reload.tenant_id).to eq('acme')
    end
  end

  describe 'required fields' do
    it 'needs display_name, primary_color_hex and cdn_base' do
      %i[display_name primary_color_hex cdn_base].each do |attr|
        expect(build(:tenant, attr => nil)).not_to be_valid, "expected #{attr} to be required"
      end
    end

    it 'needs primary_color_hex to be #RRGGBB' do
      expect(build(:tenant, primary_color_hex: '#ff6600')).to be_valid
      ['FF6600', '#FF66', '#GG6600', 'red'].each do |bad|
        expect(build(:tenant, primary_color_hex: bad)).not_to be_valid
      end
    end
  end

  describe 'URLs' do
    it 'accepts https URLs for cdn_base, catalog_index_base_url and logo_url' do
      tenant = build(:tenant, catalog_index_base_url: 'https://acme.example.com/zealot-index',
                              logo_url: 'https://acme.example.com/logo.png', logo_sha256: 'a' * 64)
      expect(tenant).to be_valid
    end

    it 'refuses http, non-URLs and hostless values' do
      ['http://cdn.example.com', 'cdn.example.com', 'https://', 'javascript:alert(1)'].each do |bad|
        expect(build(:tenant, cdn_base: bad)).not_to be_valid, "expected #{bad.inspect} to be invalid"
      end
    end

    it 'treats a blank optional URL as absent' do
      tenant = build(:tenant, catalog_index_base_url: '', logo_url: '')
      expect(tenant).to be_valid
      expect(tenant.catalog_index_base_url).to be_nil
      expect(tenant.logo_url).to be_nil
    end
  end

  describe 'logo_sha256' do
    it 'is required when logo_url is present' do
      expect(build(:tenant, logo_url: 'https://acme.example.com/logo.png')).not_to be_valid
    end

    it 'must be 64 lowercase hex characters, and is downcased first' do
      tenant = build(:tenant, logo_url: 'https://acme.example.com/logo.png', logo_sha256: 'A' * 64)
      expect(tenant).to be_valid
      expect(tenant.logo_sha256).to eq('a' * 64)
      expect(build(:tenant, logo_url: 'https://acme.example.com/logo.png', logo_sha256: 'abc')).not_to be_valid
    end
  end

  describe 'domains' do
    it 'defaults to empty, which is valid (not resolved by domain)' do
      expect(create(:tenant).domains).to eq([])
    end

    it 'normalizes like the resolver: case, port, trailing dot, duplicates' do
      tenant = create(:tenant, domains: ['Store.Acme.Example.com:8080', 'store.acme.example.com.', 'shop.acme.example.com'])
      expect(tenant.domains).to eq(%w[store.acme.example.com shop.acme.example.com])
    end

    it 'refuses entries that are not plain hostnames' do
      ['[::1]', 'not a host', 'a_b.example.com', 'https://store.example.com'].each do |bad|
        expect(build(:tenant, domains: [bad])).not_to be_valid, "expected #{bad.inspect} to be invalid"
      end
    end

    it 'refuses a domain another tenant already claims' do
      create(:tenant, domains: ['store.acme.example.com'])
      other = build(:tenant, domains: ['shop.other.example.com', 'STORE.acme.example.com'])

      expect(other).not_to be_valid
      expect(other.errors[:domains]).to be_present
    end

    it 'does not conflict with its own domains on update' do
      tenant = create(:tenant, domains: ['store.acme.example.com'])
      expect(tenant.update(display_name: 'Renamed')).to be(true)
      expect(tenant.update(domains: ['store.acme.example.com', 'new.acme.example.com'])).to be(true)
    end
  end

  # Task 37b-ii-t3: flagged questions resolved before the admin views exist.
  describe 'reserved tenant ids' do
    it 'refuses labels the deployment uses for itself' do
      %w[www api admin app cdn console mail static assets].each do |label|
        expect(build(:tenant, tenant_id: label)).not_to be_valid, "expected #{label} to be reserved"
      end
    end

    it 'still accepts an ordinary label' do
      expect(build(:tenant, tenant_id: 'acme')).to be_valid
    end
  end

  describe 'the deployment\'s own hosts' do
    around do |example|
      keep = ENV.to_h.slice('ZEALOT_DOMAIN', 'TENANT_BASE_DOMAIN')
      ENV.delete('ZEALOT_DOMAIN')
      ENV.delete('TENANT_BASE_DOMAIN')
      example.run
    ensure
      ENV.delete('ZEALOT_DOMAIN')
      ENV.delete('TENANT_BASE_DOMAIN')
      keep.each { |k, v| ENV[k] = v }
    end

    it 'refuses the primary host from ZEALOT_DOMAIN, however it is typed' do
      ENV['ZEALOT_DOMAIN'] = 'console.example.com:443'
      tenant = build(:tenant, domains: ['Console.Example.com.'])

      expect(tenant).not_to be_valid
      expect(tenant.errors[:domains].join).to include('console.example.com')
    end

    it 'refuses the TENANT_BASE_DOMAIN itself but allows a host beneath it' do
      ENV['TENANT_BASE_DOMAIN'] = 'stores.example.com'

      expect(build(:tenant, domains: ['stores.example.com'])).not_to be_valid
      expect(build(:tenant, domains: ['acme.stores.example.com'])).to be_valid
    end

    it 'refuses localhost' do
      expect(build(:tenant, domains: ['localhost'])).not_to be_valid
    end

    it 'leaves an unrelated host alone' do
      ENV['ZEALOT_DOMAIN'] = 'console.example.com'
      expect(build(:tenant, domains: ['store.acme.example.com'])).to be_valid
    end

    it 'does not block an unrelated edit of a tenant saved before the host was reserved' do
      tenant = create(:tenant, domains: ['store.acme.example.com'])
      ENV['ZEALOT_DOMAIN'] = 'store.acme.example.com'

      expect(tenant.update(display_name: 'Renamed')).to be(true)
    end

    it 'still refuses it when the domains are edited' do
      tenant = create(:tenant, domains: ['store.acme.example.com'])
      ENV['ZEALOT_DOMAIN'] = 'store.acme.example.com'

      expect(tenant.update(domains: ['store.acme.example.com', 'shop.acme.example.com'])).to be(false)
    end
  end

  describe 'domains_text (the admin form field)' do
    it 'splits on new lines, commas and spaces, and drops blanks' do
      tenant = build(:tenant, domains_text: "Store.Acme.example.com\r\n shop.acme.example.com, \n\n")
      expect(tenant).to be_valid
      expect(tenant.domains).to eq(%w[store.acme.example.com shop.acme.example.com])
    end

    it 'round-trips one host per line' do
      expect(build(:tenant, domains: %w[a.example.com b.example.com]).domains_text).to eq("a.example.com\nb.example.com")
    end

    it 'keeps a pasted URL as one entry so validation refuses it' do
      tenant = build(:tenant, domains_text: 'https://store.acme.example.com/')
      expect(tenant).not_to be_valid
    end
  end

  describe 'registry cache' do
    it 'is dropped after a committed create and update, so an edit shows in this process at once' do
      allow(Zealot::TenantRegistry).to receive(:reset!)

      tenant = create(:tenant)
      tenant.update!(display_name: 'Renamed')

      expect(Zealot::TenantRegistry).to have_received(:reset!).at_least(:twice)
    end
  end

  describe 'Zealot::TenantResolver contract' do
    it 'is resolved by its domain through the resolver' do
      tenant = create(:tenant, domains: ['store.acme.example.com'])
      resolved = Zealot::TenantResolver.resolve('store.acme.example.com', tenants: [tenant], base_domain: nil)

      expect(resolved).to eq(tenant)
    end

    it 'leaves a contested domain to the default tenant' do
      a = create(:tenant, domains: ['store.acme.example.com'])
      b = create(:tenant, domains: ['shop.other.example.com'])
      # Both claim it only if the validation was bypassed (the race the model can't close).
      b.update_columns(domains: ['store.acme.example.com'])

      resolved = Zealot::TenantResolver.resolve('store.acme.example.com', tenants: [a, b], base_domain: nil)
      expect(resolved.tenant_id).to eq(Zealot::TenantResolver::DEFAULT_TENANT_ID)
    end
  end

  # Task 38a: the parent link only. Cycle prevention and the tree queries are 38b, so nothing here
  # exercises a cycle longer than a tenant naming itself (the one thing the database enforces).
  describe 'parent and children (38a)' do
    it 'is a root tenant by default' do
      tenant = create(:tenant)

      expect(tenant.parent).to be_nil
      expect(tenant.parent_tenant_id).to be_nil
      expect(tenant.children).to be_empty
    end

    it 'can be given a parent, and the parent lists it as a child' do
      parent = create(:tenant, tenant_id: 'parent-co')
      child = create(:tenant, tenant_id: 'child-co', parent: parent)

      expect(child.reload.parent).to eq(parent)
      expect(parent.children).to contain_exactly(child)
    end

    it 'allows any depth (a grandchild has a grandparent two hops away)' do
      root = create(:tenant, tenant_id: 'root-co')
      mid = create(:tenant, tenant_id: 'mid-co', parent: root)
      leaf = create(:tenant, tenant_id: 'leaf-co', parent: mid)

      expect(leaf.reload.parent.parent).to eq(root)
    end

    it 'refuses destroy while it has children, and leaves the children alone' do
      parent = create(:tenant, tenant_id: 'parent-co')
      child = create(:tenant, tenant_id: 'child-co', parent: parent)

      expect(parent.destroy).to be(false)
      expect(parent.errors[:base]).to be_present
      expect(Tenant.exists?(parent.id)).to be(true)
      expect(child.reload.parent).to eq(parent)
    end

    it 'can be destroyed once its children are gone or moved away' do
      parent = create(:tenant, tenant_id: 'parent-co')
      child = create(:tenant, tenant_id: 'child-co', parent: parent)

      child.update!(parent: nil)

      expect(parent.reload.destroy).to be_truthy
    end

    it 'destroys a child without touching its parent' do
      parent = create(:tenant, tenant_id: 'parent-co')
      child = create(:tenant, tenant_id: 'child-co', parent: parent)

      expect(child.destroy).to be_truthy
      expect(Tenant.exists?(parent.id)).to be(true)
    end

    it 'refuses to point at a tenant row that does not exist (foreign key)' do
      tenant = create(:tenant)

      expect { tenant.update_columns(parent_tenant_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'refuses to be its own parent at the database level' do
      tenant = create(:tenant)

      expect { tenant.update_columns(parent_tenant_id: tenant.id) }.to raise_error(ActiveRecord::StatementInvalid, /tenants_parent_not_self/)
    end

    it 'leaves every existing tenant behaviour alone: a tenant with a parent still resolves and validates as before' do
      parent = create(:tenant, tenant_id: 'parent-co')

      expect(build(:tenant, tenant_id: 'child-co', parent: parent, domains: ['child.example.com'])).to be_valid
    end
  end

  # Task 38b: tree queries (plain recursive SQL) and the cycle / depth check. Fixture tree:
  #
  #   root ─┬─ child ─── grandchild
  #         └─ sibling
  #   other-root (a separate tree)
  describe 'tree queries and cycle check (38b)' do
    let!(:root) { create(:tenant, tenant_id: 'root-co') }
    let!(:child) { create(:tenant, tenant_id: 'child-co', parent: root) }
    let!(:grandchild) { create(:tenant, tenant_id: 'grandchild-co', parent: child) }
    let!(:sibling) { create(:tenant, tenant_id: 'sibling-co', parent: root) }
    let!(:other_root) { create(:tenant, tenant_id: 'other-root') }

    describe '#ancestors / #ancestor_ids' do
      it 'lists every tenant above, nearest parent first' do
        expect(grandchild.ancestor_ids).to eq([child.id, root.id])
        expect(grandchild.ancestors).to contain_exactly(child, root)
      end

      it 'is empty for a root tenant' do
        expect(root.ancestor_ids).to eq([])
        expect(root.ancestors).to be_empty
      end

      it 'never includes siblings, cousins or the tenant itself' do
        expect(child.ancestors).to contain_exactly(root)
        expect(sibling.ancestors).to contain_exactly(root)
      end

      it 'works for an unsaved tenant built with a parent' do
        expect(build(:tenant, parent: grandchild).ancestor_ids).to eq([grandchild.id, child.id, root.id])
      end
    end

    describe '#descendants / #descendant_ids' do
      it 'lists every tenant beneath, at any depth' do
        expect(root.descendants).to contain_exactly(child, grandchild, sibling)
        expect(child.descendants).to contain_exactly(grandchild)
      end

      it 'lists children before deeper tenants' do
        expect(root.descendant_ids.last).to eq(grandchild.id)
      end

      it 'is empty for a leaf, and for an unsaved tenant' do
        expect(grandchild.descendants).to be_empty
        expect(build(:tenant).descendant_ids).to eq([])
      end

      it 'never includes ancestors, siblings, other trees or the tenant itself' do
        expect(child.descendants).not_to include(root, sibling, other_root, child)
        expect(other_root.descendants).to be_empty
      end
    end

    describe '#depth' do
      it 'counts the levels above' do
        expect([root.depth, child.depth, grandchild.depth]).to eq([0, 1, 2])
      end
    end

    describe 'cycle prevention' do
      it 'refuses to make a tenant its own parent' do
        root.parent = root

        expect(root).not_to be_valid
        expect(root.errors[:parent_tenant_id]).to be_present
      end

      it 'refuses a direct cycle (the parent moves under its own child)' do
        root.parent = child

        expect(root).not_to be_valid
        expect(root.errors.details[:parent_tenant_id]).to include(error: :cycle)
      end

      it 'refuses an indirect cycle (the parent moves under its own grandchild)' do
        root.parent = grandchild

        expect(root).not_to be_valid
        expect(root.errors.details[:parent_tenant_id]).to include(error: :cycle)
      end

      it 'refuses it on update and leaves the stored tree untouched' do
        expect(root.update(parent: grandchild)).to be(false)
        expect(root.reload.parent_tenant_id).to be_nil
        expect(grandchild.reload.ancestor_ids).to eq([child.id, root.id])
      end

      it 'allows moving a subtree under a tenant that is not in it' do
        expect(child.update(parent: other_root)).to be(true)
        expect(grandchild.reload.ancestor_ids).to eq([child.id, other_root.id])
        expect(root.reload.descendants).to contain_exactly(sibling)
      end

      it 'allows moving a tenant to a sibling and back to a root' do
        expect(grandchild.update(parent: sibling)).to be(true)
        expect(grandchild.update(parent: nil)).to be(true)
        expect(grandchild.reload.ancestors).to be_empty
      end

      it 'does not re-check the tree when something other than the parent changes' do
        expect(root.update(display_name: 'Renamed')).to be(true)
      end
    end

    describe 'the depth cap' do
      let(:cap) { described_class::MAX_TREE_DEPTH }

      def chain_of(length)
        length.times.inject(nil) { |parent, i| create(:tenant, tenant_id: "deep-#{i}", parent: parent) }
      end

      it 'accepts a tree exactly at the cap' do
        expect(chain_of(cap).depth).to eq(cap - 1)
      end

      it 'refuses a child that would exceed the cap' do
        bottom = chain_of(cap)
        too_deep = build(:tenant, tenant_id: 'one-too-many', parent: bottom)

        expect(too_deep).not_to be_valid
        expect(too_deep.errors.details[:parent_tenant_id]).to include(error: :too_deep, max: cap)
      end

      it 'counts the moved tenant\'s own subtree, not just where it lands' do
        bottom = chain_of(cap - 1)

        # root -> child -> grandchild is three levels; under a chain of cap - 1 that makes cap + 2.
        expect(root.update(parent: bottom)).to be(false)
        expect(root.errors.details[:parent_tenant_id]).to include(error: :too_deep, max: cap)
      end

      it 'stops walking a corrupted loop instead of running forever' do
        # Bypass validations to fake bad data: two tenants that are each other's parent.
        other_root.update_columns(parent_tenant_id: root.id)
        root.update_columns(parent_tenant_id: other_root.id)

        expect(described_class.chain_up(root.id).size).to be <= cap + 1
        expect(root.reload.descendant_ids).to include(other_root.id)
        expect(build(:tenant, parent: root)).not_to be_valid
      end
    end

    it 'leaves the default tenant out of the tree (it is not a row)' do
      expect(described_class.where(parent_tenant_id: nil)).to contain_exactly(root, other_root)
    end
  end
end
