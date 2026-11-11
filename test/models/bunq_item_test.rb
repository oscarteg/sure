require "test_helper"

class BunqItemTest < ActiveSupport::TestCase
  test "key rotation resets installation context without forgetting linked user" do
    item = bunq_items(:one)
    item.update!(private_key: "private", installation_token: "token", server_public_key: "public", device_id: "3", user_id: "7")
    item.update!(api_key: "rotated-test-key")
    item.reload
    assert_nil item.private_key
    assert_nil item.installation_token
    assert_nil item.server_public_key
    assert_nil item.device_id
    assert_equal "7", item.user_id
  end

  test "existing accounts cannot move between environments" do
    item = bunq_items(:one)
    assert_not item.update(environment: "production")
    assert item.errors.of_kind?(:environment, :invalid)
  end

  test "needs setup excludes linked ignored and inactive accounts" do
    item = bunq_items(:one)
    checking = bunq_accounts(:checking)
    ignored = item.bunq_accounts.create!(account_id: "43", name: "Ignored", currency: "EUR", ignored: true, account_status: "ACTIVE")
    inactive = item.bunq_accounts.create!(account_id: "44", name: "Closed", currency: "EUR", account_status: "CANCELLED")
    assert_equal [ checking.id ], item.bunq_accounts.needs_setup.pluck(:id)
    account = Account.create!(family: item.family, name: "Linked", currency: "EUR", balance: 0, accountable: Depository.new(subtype: "checking"))
    AccountProvider.create!(account: account, provider: checking)
    assert_empty item.bunq_accounts.needs_setup
    assert_equal 1, item.linked_accounts_count
    assert_equal 0, item.unlinked_accounts_count
    assert_equal 3, item.total_accounts_count
    assert ignored.ignored?
    assert_equal "CANCELLED", inactive.account_status
  end

  test "unlink preserves canonical accounts and their entries" do
    item = bunq_items(:one)
    provider_account = bunq_accounts(:checking)
    account = Account.create!(family: item.family, name: "Keep", currency: "EUR", balance: 0, accountable: Depository.new(subtype: "checking"))
    link = AccountProvider.create!(account: account, provider: provider_account)
    assert_equal [ link.id ], item.unlink_all!(dry_run: true).first[:provider_link_ids]
    assert AccountProvider.exists?(link.id)
    item.unlink_all!
    assert_not AccountProvider.exists?(link.id)
    assert Account.exists?(account.id)
    assert BunqAccount.exists?(provider_account.id)
  end
end
