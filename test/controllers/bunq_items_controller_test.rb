require "test_helper"

class BunqItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
    @bunq_item = @family.bunq_items.create!(
      name: "Main bunq", api_key: "bunq-personal-key", environment: "sandbox"
    )
    @bunq_account = @bunq_item.bunq_accounts.create!(
      name: "Everyday", account_id: "101", currency: "EUR", current_balance: 125,
      account_type: "MonetaryAccountBank", account_status: "ACTIVE"
    )
    Provider::Bunq.any_instance.stubs(:get_accounts).returns([])
  end

  test "create scopes the connection to the current family and starts a sync" do
    assert_difference "BunqItem.count", 1 do
      post bunq_items_url, params: {
        bunq_item: { name: "Second bunq", api_key: "new-key", environment: "sandbox", family_id: families(:empty).id }
      }
    end

    assert_redirected_to settings_providers_path
    created = @family.bunq_items.find_by!(name: "Second bunq")
    assert_equal "new-key", created.api_key
    assert_equal 1, created.syncs.count
  end

  test "invalid create renders the panel without saving a connection" do
    assert_no_difference "BunqItem.count" do
      post bunq_items_url, params: { bunq_item: { name: "Invalid", api_key: "" } }, as: :turbo_stream
    end

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "bunq-providers-panel"
  end

  test "update preserves a blank key and cannot change the environment" do
    patch bunq_item_url(@bunq_item), params: {
      bunq_item: { name: "Renamed bunq", api_key: "", environment: "production" }
    }, as: :turbo_stream

    assert_turbo_stream action: "replace", target: "bunq-providers-panel"
    assert_equal "Renamed bunq", @bunq_item.reload.name
    assert_equal "bunq-personal-key", @bunq_item.api_key
    assert_equal "sandbox", @bunq_item.environment
    refute_includes response.body, "bunq-personal-key"
    assert_select "input[name='bunq_item[api_key]'][value]", 0
  end

  test "setup refreshes balances and offers active accounts with a scoped choice" do
    Provider::Bunq.any_instance.stubs(:get_accounts).returns([
      {
        "id" => 101, "description" => "Everyday", "currency" => "EUR",
        "balance" => { "value" => "250.50", "currency" => "EUR" },
        "status" => "ACTIVE", "account_type" => "MonetaryAccountBank"
      }
    ])

    get setup_accounts_bunq_item_url(@bunq_item)

    assert_response :success
    assert_equal BigDecimal("250.50"), @bunq_account.reload.current_balance
    assert_select "select[name='account_types[#{@bunq_account.id}]'] option[selected='selected'][value=Depository]", 1
  end

  test "a failed refresh keeps saved accounts available and hides error details" do
    Provider::Bunq.any_instance.stubs(:get_accounts).raises(Provider::Bunq::BunqError.new(:authentication_error))

    get setup_accounts_bunq_item_url(@bunq_item)

    assert_response :success
    assert_select "select[name='account_types[#{@bunq_account.id}]']", 1
    assert_select "button[type=submit][disabled]", false
    refute_includes response.body, @bunq_item.api_key
    assert_equal BigDecimal("125"), @bunq_account.reload.current_balance
  end

  test "setup creates savings accounts and remembers skipped accounts" do
    savings = @bunq_item.bunq_accounts.create!(
      name: "Savings", account_id: "102", currency: "EUR", current_balance: 800,
      account_type: "MonetaryAccountSavings", account_status: "ACTIVE"
    )

    assert_difference [ "Account.count", "AccountProvider.count" ], 1 do
      post complete_account_setup_bunq_item_url(@bunq_item), params: {
        account_types: { savings.id => "Depository", @bunq_account.id => "skip" }
      }
    end

    assert_redirected_to accounts_path
    assert_equal "savings", savings.reload.current_account.accountable.subtype
    assert_equal BigDecimal("800"), savings.current_account.balance
    assert @bunq_account.reload.ignored?
    refute @bunq_item.reload.pending_account_setup?
  end

  test "repeated account linking does not create duplicates" do
    params = { bunq_item_id: @bunq_item.id, account_ids: [ @bunq_account.id ] }
    post link_accounts_bunq_items_url, params: params
    assert_redirected_to accounts_path

    assert_no_difference [ "Account.count", "AccountProvider.count" ] do
      post link_accounts_bunq_items_url, params: params
    end

    assert_equal @family, @bunq_account.reload.current_account.family
  end

  test "linking an existing account preserves it without creating another account" do
    account = create_existing_account

    assert_no_difference "Account.count" do
      assert_difference "AccountProvider.count", 1 do
        post link_existing_account_bunq_items_url, params: {
          bunq_item_id: @bunq_item.id, bunq_account_id: @bunq_account.id, account_id: account.id
        }
      end
    end

    assert_redirected_to accounts_path
    assert_equal account, @bunq_account.reload.current_account
    assert_equal "Existing bunq", account.reload.name
  end

  test "existing account picker only offers compatible active accounts" do
    account = create_existing_account
    incompatible = @bunq_item.bunq_accounts.create!(
      name: "Dollars", account_id: "103", currency: "USD",
      account_type: "MonetaryAccountBank", account_status: "ACTIVE"
    )

    get select_existing_account_bunq_items_url, params: { bunq_item_id: @bunq_item.id, account_id: account.id }

    assert_response :success
    assert_select "input[name=bunq_account_id][value='#{@bunq_account.id}']", 1
    assert_select "input[name=bunq_account_id][value='#{incompatible.id}']", 0
  end

  test "existing account linking rejects currency mismatch" do
    account = create_existing_account(currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_bunq_items_url, params: {
        bunq_item_id: @bunq_item.id, bunq_account_id: @bunq_account.id, account_id: account.id
      }
    end

    assert_redirected_to accounts_path
    assert_nil @bunq_account.reload.account_provider
  end

  test "closed bunq accounts cannot be linked" do
    @bunq_account.update!(account_status: "CLOSED")
    account = create_existing_account

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_bunq_items_url, params: {
        bunq_item_id: @bunq_item.id, bunq_account_id: @bunq_account.id, account_id: account.id
      }
    end

    assert_response :not_found
  end

  test "connection actions cannot address a different family" do
    foreign = families(:empty).bunq_items.create!(name: "Foreign bunq", api_key: "foreign-secret")

    assert_no_difference [ "AccountProvider.count", "Sync.count" ] do
      [
        [ :patch, bunq_item_url(foreign), { bunq_item: { name: "Changed" } } ],
        [ :post, sync_bunq_item_url(foreign), {} ],
        [ :get, setup_accounts_bunq_item_url(foreign), {} ],
        [ :post, link_accounts_bunq_items_url, { bunq_item_id: foreign.id, account_ids: [ @bunq_account.id ] } ],
        [ :delete, bunq_item_url(foreign), {} ]
      ].each do |method, path, params|
        public_send method, path, params: params
        assert_response :not_found
        refute_includes response.body, "foreign-secret"
      end
    end
    assert_equal "Foreign bunq", foreign.reload.name
    refute foreign.scheduled_for_deletion?
  end

  test "existing account linking cannot address a different family account" do
    account = create_existing_account(family: families(:empty))

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_bunq_items_url, params: {
        bunq_item_id: @bunq_item.id, bunq_account_id: @bunq_account.id, account_id: account.id
      }
    end
    assert_response :not_found
  end

  test "non admins cannot create edit sync link or disconnect connections" do
    sign_in users(:family_member)

    assert_no_difference [ "BunqItem.count", "AccountProvider.count", "Sync.count" ] do
      [
        [ :post, bunq_items_url, { bunq_item: { api_key: "forbidden" } } ],
        [ :patch, bunq_item_url(@bunq_item), { bunq_item: { name: "Changed" } } ],
        [ :post, sync_bunq_item_url(@bunq_item), {} ],
        [ :get, setup_accounts_bunq_item_url(@bunq_item), {} ],
        [ :post, link_accounts_bunq_items_url, { bunq_item_id: @bunq_item.id, account_ids: [ @bunq_account.id ] } ],
        [ :delete, bunq_item_url(@bunq_item), {} ]
      ].each do |method, path, params|
        public_send method, path, params: params, as: :turbo_stream
        assert_response :forbidden
      end
    end
    assert_equal "Main bunq", @bunq_item.reload.name
    refute @bunq_item.scheduled_for_deletion?
  end

  test "account linking ignores an external return URL" do
    post link_accounts_bunq_items_url, params: {
      bunq_item_id: @bunq_item.id, account_ids: [ @bunq_account.id ], return_to: "//example.test"
    }

    assert_redirected_to accounts_path
    assert @bunq_account.reload.current_account
  end

  test "disconnect preserves Sure accounts" do
    account = create_existing_account
    AccountProvider.create!(account: account, provider: @bunq_account)
    DestroyJob.stubs(:perform_later)

    assert_no_difference "Account.count" do
      delete bunq_item_url(@bunq_item)
    end

    assert_redirected_to settings_providers_path
    assert @bunq_item.reload.scheduled_for_deletion?
    assert_nil @bunq_account.reload.account_provider
    assert Account.exists?(account.id)
  end

  private
    def create_existing_account(currency: "EUR", family: @family)
      family.accounts.create!(
        name: "Existing bunq", currency: currency, balance: 125,
        accountable: Depository.new(subtype: "checking")
      )
    end
end
