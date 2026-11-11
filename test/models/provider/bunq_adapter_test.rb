require "test_helper"

class Provider::BunqAdapterTest < ActiveSupport::TestCase
  test "adapter exposes item institution and depository contract" do
    account = bunq_accounts(:checking)
    adapter = Provider::BunqAdapter.new(account)
    assert_equal account.bunq_item, adapter.item
    assert_equal "bunq", adapter.provider_name
    assert_equal "bunq", adapter.institution_name
    assert_equal "bunq.com", adapter.institution_domain
    assert_equal [ "Depository" ], Provider::BunqAdapter.supported_account_types
    assert_equal BunqItem, Provider::BunqAdapter.connection_item_class
    assert_not adapter.can_delete_holdings?
  end

  test "provider resolution never crosses family boundaries or returns deleting items" do
    item = bunq_items(:one)
    assert_instance_of Provider::Bunq, Provider::BunqAdapter.build_provider(family: item.family, bunq_item_id: item.id)
    assert_nil Provider::BunqAdapter.build_provider(family: families(:empty), bunq_item_id: item.id)
    item.update!(scheduled_for_deletion: true)
    assert_nil Provider::BunqAdapter.build_provider(family: item.family, bunq_item_id: item.id)
  end

  test "connection discovery exposes only configured active family items" do
    item = bunq_items(:one)
    config = Provider::BunqAdapter.connection_configs(family: item.family).sole
    assert_equal "bunq_#{item.id}", config.fetch(:key)
    assert config.fetch(:can_connect)
    new_path = config.fetch(:new_account_path).call("Depository", "/accounts")
    existing_path = config.fetch(:existing_account_path).call("existing-account")
    assert_equal "/bunq_items/select_accounts", URI.parse(new_path).path
    assert_equal item.id, Rack::Utils.parse_query(URI.parse(new_path).query).fetch("bunq_item_id")
    assert_equal "existing-account", Rack::Utils.parse_query(URI.parse(existing_path).query).fetch("account_id")
    assert_empty Provider::BunqAdapter.connection_configs(family: families(:empty))
    item.update!(scheduled_for_deletion: true)
    assert_empty Provider::BunqAdapter.connection_configs(family: item.family)
  end
end
