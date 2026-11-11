require "test_helper"

class BunqAccountTest < ActiveSupport::TestCase
  test "snapshot maps savings and decimal balance without changing canonical account name" do
    provider_account = bunq_accounts(:checking)
    provider_account.upsert_bunq_snapshot!(
      { "id" => 42, "description" => "Savings", "currency" => "EUR", "status" => "ACTIVE",
        "account_type" => "MonetaryAccountSavings", "balance" => { "value" => "123.4567", "currency" => "EUR" } }
    )
    assert_equal "42", provider_account.account_id
    assert_equal BigDecimal("123.4567"), provider_account.current_balance
    assert_equal "Depository", provider_account.suggested_account_type
    assert_equal "savings", provider_account.suggested_subtype
    assert_equal "bunq.com", provider_account.institution_metadata.fetch("domain")
  end

  test "malformed balance never becomes a zero balance" do
    account = bunq_accounts(:checking)
    assert_raises(Provider::Bunq::BunqError) do
      account.upsert_bunq_snapshot!(
        { "id" => 42, "currency" => "EUR", "status" => "ACTIVE", "account_type" => "MonetaryAccountBank", "balance" => { "value" => "not-money" } }
      )
    end
    assert_equal BigDecimal("123.45"), account.reload.current_balance
  end
end
