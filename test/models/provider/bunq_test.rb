require "test_helper"

class Provider::BunqTest < ActiveSupport::TestCase
  BASE = "https://public-api.sandbox.bunq.com/v1/".freeze

  setup do
    @item = bunq_items(:one)
    @client_key = OpenSSL::PKey::RSA.new(2048)
    @server_key = OpenSSL::PKey::RSA.new(2048)
    @item.update!(private_key: @client_key.to_pem, installation_token: "installation",
      server_public_key: @server_key.public_key.to_pem, device_id: "5", user_id: "7")
    session_stub
    @client = Provider::Bunq.new(@item)
  end

  test "signs exact POST JSON and empty GET bytes and authenticates with session token" do
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 }) do |request|
      assert_equal "session", request.headers["X-Bunq-Client-Authentication"]
      assert @client_key.public_key.verify("SHA256", Base64.strict_decode64(request.headers.fetch("X-Bunq-Client-Signature")), "")
    end.to_return(signed(Response: []))

    assert_empty @client.get_accounts
    assert_requested(:post, "#{BASE}session-server") do |request|
      assert_equal '{"secret":"bunq-test-key"}', request.body
      assert_equal "installation", request.headers["X-Bunq-Client-Authentication"]
      @client_key.public_key.verify("SHA256", Base64.strict_decode64(request.headers.fetch("X-Bunq-Client-Signature")), request.body)
    end
  end

  test "installation then device then session persists each successful stage on later failure" do
    @item.update!(installation_token: nil, device_id: nil, server_public_key: nil)
    installation = stub_request(:post, "#{BASE}installation").with do |request|
      key = OpenSSL::PKey::RSA.new(JSON.parse(request.body).fetch("client_public_key"))
      key.verify("SHA256", Base64.strict_decode64(request.headers.fetch("X-Bunq-Client-Signature")), request.body)
    end.to_return(signed(Response: [ { Token: { token: "new-installation" } },
      { ServerPublicKey: { server_public_key: @server_key.public_key.to_pem } } ]))
    device = stub_request(:post, "#{BASE}device-server").with do |request|
      body = JSON.parse(request.body)
      assert_not body.key?("permitted_ips")
      assert_equal "new-installation", request.headers["X-Bunq-Client-Authentication"]
    end.to_return(signed(Response: [ { Id: { id: 6 } } ]))
    stub_request(:post, "#{BASE}session-server").to_return(status: 403, body: '{"secret":"not for diagnostics"}')

    error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    assert_equal :unauthorized, error.error_type
    @item.reload
    assert_equal "new-installation", @item.installation_token
    assert_equal "6", @item.device_id
    assert_equal @server_key.public_key.to_pem, @item.server_public_key

    session_stub
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 }).to_return(signed(Response: []))
    assert_empty Provider::Bunq.new(@item).get_accounts
    assert_requested installation, times: 1
    assert_requested device, times: 1
  end

  test "renews expired GET authentication once and never loops on rejection" do
    get = stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
      .to_return({ status: 401, body: "{}" }, signed(Response: []))
    assert_empty @client.get_accounts
    assert_requested get, times: 2
    assert_requested :post, "#{BASE}session-server", times: 2
  end

  test "a second expired GET response surfaces without a third attempt" do
    get = stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
      .to_return(status: 401, body: "{}")
    error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    assert_equal :unauthorized, error.error_type
    assert_requested get, times: 2
    assert_requested :post, "#{BASE}session-server", times: 2
  end

  test "rejects changed user identity before requesting any accounts" do
    session_stub(user_id: 8)
    error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    assert_equal :identity_changed, error.error_type
    assert_equal "7", @item.reload.user_id
    assert_not_requested :get, /monetary-account/
  end

  test "accepts documented person company and API key user wrappers" do
    %w[UserPerson UserCompany UserApiKey].each do |type|
      session_stub(type: type)
      stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 }).to_return(signed(Response: []))
      assert_empty Provider::Bunq.new(@item).get_accounts
    end
  end

  test "rejects tampered signed successful responses" do
    response = signed(Response: [])
    response[:body] = { Response: [ { MonetaryAccountBank: { id: 99, status: "ACTIVE" } } ] }.to_json
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 }).to_return(response)
    error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    assert_equal :invalid_signature, error.error_type
  end

  test "rejects unsigned and malformed successful responses" do
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
      .to_return(status: 200, body: '{"Response":[]}')
    assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
      .to_return(signed(Response: {}))
    assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }

    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
      .to_return(signed(Response: [ { MonetaryAccountBank: { id: 42 } } ]))
    error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    assert_equal :parse_error, error.error_type
  end

  test "normalizes only active own-funds account wrappers" do
    wrappers = Provider::Bunq::ACCOUNT_TYPES.each_with_index.map do |type, index|
      { type => { id: index + 1, status: "ACTIVE", description: type } }
    end
    wrappers << { MonetaryAccountBank: { id: 10, status: "CANCELLED" } }
    wrappers << { MonetaryAccountExternal: { id: 11, status: "ACTIVE" } }
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
      .to_return(signed(Response: wrappers))
    accounts = @client.get_accounts
    assert_equal %w[1 2 3 4], accounts.map { |account| account.fetch("id") }
    assert_equal Provider::Bunq::ACCOUNT_TYPES, accounts.map { |account| account.fetch("account_type") }
  end

  test "follows every older page including empty pages and filters history by date" do
    path = "#{BASE}user/7/monetary-account/42/payment"
    stub_request(:get, path).with(query: { count: 200 }).to_return(signed(
      Response: [ { Payment: { id: 2, created: "2026-05-02 12:00:00.000000" } } ],
      Pagination: { older_url: "/v1/user/7/monetary-account/42/payment?older_id=2&count=200" }
    ))
    stub_request(:get, path).with(query: { older_id: 2, count: 200 }).to_return(signed(
      Response: [ { Payment: { id: 1, created: "2026-04-02 12:00:00.000000" } } ],
      Pagination: { older_url: "#{path}?older_id=1&count=200" }
    ))
    last = stub_request(:get, path).with(query: { older_id: 1, count: 200 }).to_return(signed(Response: []))
    assert_equal [ "2" ], @client.get_transactions("42", start_date: Date.new(2026, 5, 1)).map { |payment| payment.fetch("id") }
    assert_requested last
  end

  test "rejects foreign insecure wrong-resource and malformed pagination" do
    [
      "https://evil.example/v1/user/7/monetary-account",
      "http://public-api.sandbox.bunq.com/v1/user/7/monetary-account",
      "/v1/user/8/monetary-account",
      "/v1/user/7/monetary-account?count=201",
      "https://user:password@public-api.sandbox.bunq.com/v1/user/7/monetary-account",
      "https://[broken", 12, ""
    ].each do |url|
      stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 })
        .to_return(signed(Response: [], Pagination: { older_url: url }))
      error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
      assert_equal :invalid_url, error.error_type
    end
    assert_not_requested :get, /evil\.example/
  end

  test "pagination cycles fail rather than accepting incomplete history" do
    stub_request(:get, "#{BASE}user/7/monetary-account").with(query: { count: 200 }).to_return(signed(
      Response: [], Pagination: { older_url: "/v1/user/7/monetary-account?count=200" }
    ))
    error = assert_raises(Provider::Bunq::BunqError) { @client.get_accounts }
    assert_equal :pagination_cycle, error.error_type
  end

  test "blank credentials are rejected without a request" do
    @item.api_key = ""
    error = assert_raises(Provider::Bunq::BunqError) { Provider::Bunq.new(@item) }
    assert_equal :configuration_error, error.error_type
  end

  private

    def signed(payload)
      body = payload.to_json
      { status: 200, body: body, headers: { "X-Bunq-Server-Signature" => Base64.strict_encode64(@server_key.sign("SHA256", body)) } }
    end

    def session_stub(user_id: 7, type: "UserPerson")
      stub_request(:post, "#{BASE}session-server").to_return(signed(
        Response: [ { Token: { token: "session" } }, { type => { id: user_id } } ]
      ))
    end
end
