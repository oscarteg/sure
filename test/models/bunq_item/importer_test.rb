require "test_helper"

class BunqItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = bunq_items(:one)
    @provider_account = bunq_accounts(:checking)
    @account = Account.create!(family: @item.family, name: "Keep my name", currency: "EUR", balance: 0, accountable: Depository.new(subtype: "checking"))
    AccountProvider.create!(account: @account, provider: @provider_account)
    @provider = mock("bunq")
  end

  test "partial history failure leaves every stored snapshot and successful sync state unchanged" do
    @item.update!(raw_payload: [ { "previous" => true } ])
    @provider_account.update!(raw_transactions_payload: [ { "id" => "old" } ])
    @provider.expects(:get_accounts).returns([ snapshot("42") ])
    @provider.expects(:get_transactions).with("42", start_date: nil).raises(Provider::Bunq::BunqError.new(:network_error))
    captured = []
    DebugLogEntry.stubs(:capture).with do |arguments|
      captured << arguments
      true
    end

    assert_raises(Provider::Bunq::BunqError) { importer.import }
    assert_equal [ { "previous" => true } ], @item.reload.raw_payload
    assert_equal [ { "id" => "old" } ], @provider_account.reload.raw_transactions_payload
    assert_nil @item.last_synced_at
    assert_equal 0, @account.entries.count
    assert captured.any? { |arguments| arguments[:account_provider] == @provider_account.account_provider && arguments[:family] == @item.family }
    assert captured.all? { |arguments| !arguments[:metadata].key?(:error_message) }
  end

  test "discovers accounts but skips fetching history for unlinked and ignored accounts" do
    @provider_account.update!(ignored: true)
    @provider.expects(:get_accounts).returns([ snapshot("42"), snapshot("43") ])
    @provider.expects(:get_transactions).never
    result = importer.import
    assert result[:success]
    assert_equal 2, @item.bunq_accounts.count
    assert_equal [ "43" ], @item.bunq_accounts.needs_setup.pluck(:account_id)
    @item.process_accounts
    assert_empty @account.entries
    assert_equal 0, @account.reload.balance
  end

  test "uses account start date before item date and keeps every fetched transaction" do
    @item.update!(sync_start_date: Date.new(2026, 1, 1))
    @provider_account.update!(sync_start_date: Date.new(2026, 2, 1))
    @provider.expects(:get_accounts).returns([ snapshot("42") ])
    @provider.expects(:get_transactions).with("42", start_date: Date.new(2026, 2, 1)).returns([ { "id" => "1" }, { "id" => "2" } ])
    assert_equal 2, importer.import[:transactions_imported]
    assert_equal [ "1", "2" ], @provider_account.reload.raw_transactions_payload.map { |row| row.fetch("id") }
  end

  private

    def importer
      BunqItem::Importer.new(@item, bunq_provider: @provider)
    end

    def snapshot(id)
      { "id" => id, "description" => "bunq Spending", "currency" => "EUR", "status" => "ACTIVE",
        "account_type" => "MonetaryAccountBank", "balance" => { "value" => "100.00" } }
    end
end
