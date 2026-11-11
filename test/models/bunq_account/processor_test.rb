require "test_helper"

class BunqAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @provider_account = bunq_accounts(:checking)
    @item = @provider_account.bunq_item
    @account = Account.create!(family: @item.family, name: "My edited account", currency: "EUR", balance: 0, accountable: Depository.new(subtype: "checking"))
    AccountProvider.create!(account: @account, provider: @provider_account)
  end

  test "imports signs decimals names FX and does not duplicate existing Citadel payment identifiers" do
    adapter = Account::ProviderImportAdapter.new(@account)
    existing = adapter.import_transaction(external_id: "101", source: "bunq", amount: BigDecimal("12.34"), currency: "EUR",
      date: Date.new(2026, 5, 1), name: "Old import", extra: { "citadel" => { "retained" => true } })
    @provider_account.update!(raw_transactions_payload: [ payment("101", "-12.34"), payment("102", "4.56") ])
    2.times { BunqAccount::Processor.new(@provider_account).process }
    assert_equal 2, @account.entries.count
    assert_equal existing.id, @account.entries.find_by!(source: "bunq", external_id: "101").id
    assert_equal BigDecimal("12.34"), existing.reload.amount
    assert_equal BigDecimal("-4.56"), @account.entries.find_by!(external_id: "102").amount
    assert_equal "Cafe - Lunch", existing.name
    assert_equal "USD", existing.transaction.extra.dig("bunq", "fx_from")
    assert_equal BigDecimal("15"), BigDecimal(existing.transaction.extra.dig("bunq", "fx_amount"))
    assert existing.transaction.extra.dig("citadel", "retained")
    assert_equal "My edited account", @account.reload.name
    assert_equal BigDecimal("123.45"), @account.balance
  end

  test "user edits and import locks survive later provider snapshots" do
    @provider_account.update!(raw_transactions_payload: [ payment("101", "-12.34") ])
    BunqAccount::Processor.new(@provider_account).process
    entry = @account.entries.find_by!(source: "bunq", external_id: "101")
    entry.update!(name: "My lunch", user_modified: true)
    @provider_account.update!(raw_transactions_payload: [ payment("101", "-20.00") ])
    BunqAccount::Processor.new(@provider_account).process
    assert_equal "My lunch", entry.reload.name
    assert_equal BigDecimal("12.34"), entry.amount
    entry.update!(import_locked: true)
    before = entry.transaction.extra
    @provider_account.update!(raw_transactions_payload: [ payment("101", "-30.00") ])
    BunqAccount::Processor.new(@provider_account).process
    assert_equal before, entry.reload.transaction.extra
    assert_equal 1, @account.entries.count
  end

  test "malformed later payment rolls back earlier entries and balance changes" do
    @provider_account.update!(raw_transactions_payload: [ payment("101", "-12.34"), payment("102", "NaN") ])
    DebugLogEntry.stubs(:capture)
    assert_raises(Provider::Bunq::BunqError) { BunqAccount::Processor.new(@provider_account).process }
    assert_empty @account.entries
    assert_equal 0, @account.reload.balance
  end

  test "item rollback preserves diagnostic family and account provider context" do
    @provider_account.update!(raw_transactions_payload: [ payment("101", "-12.34"), payment("102", "NaN") ])
    assert_raises(Provider::Bunq::BunqError) { @item.process_accounts }
    assert_empty @account.entries
    log = DebugLogEntry.where(provider_key: "bunq", account_provider: @provider_account.account_provider).order(:created_at).last
    assert log
    assert_equal @item.family_id, log.family_id
    assert_equal @account.id, log.account_id
    assert_equal @provider_account.id, log.metadata.fetch("bunq_account_id")
  end

  test "ignored unlinked and foreign family accounts cannot receive imports" do
    @provider_account.update!(ignored: true, raw_transactions_payload: [ payment("101", "-12.34") ])
    assert_nil BunqAccount::Processor.new(@provider_account).process
    @provider_account.account_provider.destroy!
    @provider_account.reload.update!(ignored: false)
    assert_nil BunqAccount::Processor.new(@provider_account).process
    foreign = Account.create!(family: families(:empty), name: "Other", currency: "EUR", balance: 0, accountable: Depository.new(subtype: "checking"))
    AccountProvider.create!(account: foreign, provider: @provider_account)
    @provider_account.reload
    DebugLogEntry.stubs(:capture)
    assert_raises(Provider::Bunq::BunqError) { BunqAccount::Processor.new(@provider_account).process }
    assert_empty foreign.entries
  end

  private

    def payment(id, value)
      { "id" => id, "created" => "2026-05-01 12:30:00.000000", "amount" => { "value" => value, "currency" => "EUR" },
        "counterparty_alias" => { "display_name" => "  Cafe  " }, "description" => "Lunch",
        "amount_local" => { "value" => "-15.00", "currency" => "USD" } }
    end
end
