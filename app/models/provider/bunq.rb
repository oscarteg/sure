require "base64"
require "json"
require "openssl"
require "set"
require "uri"

class Provider::Bunq
  include HTTParty

  BASE_URLS = {
    "production" => "https://api.bunq.com/v1/",
    "sandbox" => "https://public-api.sandbox.bunq.com/v1/"
  }.freeze
  ACCOUNT_TYPES = %w[MonetaryAccountBank MonetaryAccountSavings MonetaryAccountJoint MonetaryAccountCard].freeze

  class BunqError < StandardError
    attr_reader :error_type, :http_status

    def initialize(error_type, http_status: nil)
      @error_type = error_type
      @http_status = http_status
      super("bunq request failed (#{error_type})")
    end
  end

  attr_reader :bunq_item

  def initialize(bunq_item)
    @bunq_item = bunq_item
    unless bunq_item.credentials_configured? && BASE_URLS.key?(bunq_item.environment)
      raise BunqError.new(:configuration_error)
    end
  end

  # Flatten only active, own-funds monetary accounts, retaining their wrapper type.
  def get_accounts
    authenticate!
    fetch_pages("user/#{user_id}/monetary-account").filter_map do |wrapper|
      type = (wrapper.keys & ACCOUNT_TYPES).first
      next unless type

      data = wrapper.fetch(type)
      unless data.is_a?(Hash) && data["status"].is_a?(String) && data["status"].present?
        raise BunqError.new(:parse_error)
      end
      next unless data["status"] == "ACTIVE"

      require_id!(data["id"])
      data.merge("id" => data["id"].to_s, "account_type" => type)
    end
  end

  # Payment includes booked card payments. No MastercardAction/pending feed is used.
  def get_transactions(account_id, start_date: nil)
    authenticate!
    require_id!(account_id)
    payments = fetch_pages("user/#{user_id}/monetary-account/#{account_id}/payment").map do |wrapper|
      payment = wrapper["Payment"]
      raise BunqError.new(:parse_error) unless payment.is_a?(Hash)

      require_id!(payment["id"])
      payment.merge("id" => payment["id"].to_s)
    end
    return payments unless start_date

    cutoff = start_date.to_date
    payments.select { |payment| Date.iso8601(payment.fetch("created").to_s.split.first) >= cutoff }
  rescue KeyError, ArgumentError, TypeError
    raise BunqError.new(:parse_error), cause: nil
  end

  private

    def user_id
      bunq_item.user_id
    end

    def require_id!(value)
      raise BunqError.new(:parse_error) unless value.to_s.match?(/\A[0-9]+\z/)
    end

    def authenticate!(force: false)
      return if @session_token && !force

      failure = nil
      # Rescue inside the lock transaction: completed installation/device stages must
      # survive a later HTTP failure, or the next sync would register another device.
      bunq_item.with_lock do
        begin
          install! unless bunq_item.installation_token.present?
          register_device! unless bunq_item.device_id.present?
          session = request(:post, "session-server", token: bunq_item.installation_token, body: { secret: bunq_item.api_key })
          token = object(session, "Token").fetch("token")
          user = session.fetch("Response").filter_map { |row| row["UserPerson"] || row["UserCompany"] || row["UserApiKey"] }.first
          raise BunqError.new(:parse_error) unless user.is_a?(Hash)

          id = user["id"]
          require_id!(id)
          raise BunqError.new(:parse_error) unless token.is_a?(String) && token.present?
          if bunq_item.user_id.present? && bunq_item.user_id != id.to_s
            raise BunqError.new(:identity_changed)
          end

          bunq_item.update!(user_id: id.to_s)
          @session_token = token
        rescue StandardError => error
          failure = error
        end
      end
      raise failure if failure
    rescue KeyError, ArgumentError, TypeError
      raise BunqError.new(:parse_error), cause: nil
    end

    def install!
      bunq_item.update!(private_key: OpenSSL::PKey::RSA.new(2048).to_pem) unless bunq_item.private_key.present?
      payload = request(:post, "installation", body: { client_public_key: signing_key.public_key.to_pem }, installation: true)
      token = object(payload, "Token").fetch("token")
      key = object(payload, "ServerPublicKey").fetch("server_public_key")
      raise BunqError.new(:parse_error) unless token.is_a?(String) && token.present?

      bunq_item.update!(installation_token: token, server_public_key: key)
    end

    def register_device!
      payload = request(:post, "device-server", token: bunq_item.installation_token,
        body: { description: "Sure", secret: bunq_item.api_key })
      id = object(payload, "Id").fetch("id")
      require_id!(id)
      bunq_item.update!(device_id: id.to_s)
    end

    def object(payload, type)
      value = payload.fetch("Response").filter_map { |row| row[type] }.first
      raise BunqError.new(:parse_error) unless value.is_a?(Hash)

      value
    end

    def signing_key
      OpenSSL::PKey::RSA.new(bunq_item.private_key)
    end

    def request(method, path_or_url, token: nil, body: nil, installation: false)
      bytes = body ? JSON.generate(body) : ""
      headers = {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "User-Agent" => "Sure Finance bunq Client",
        "X-Bunq-Client-Request-Id" => SecureRandom.uuid,
        "X-Bunq-Client-Signature" => Base64.strict_encode64(signing_key.sign("SHA256", bytes))
      }
      headers["X-Bunq-Client-Authentication"] = token if token
      url = path_or_url.start_with?("https://") ? path_or_url : "#{BASE_URLS.fetch(bunq_item.environment)}#{path_or_url}"
      response = self.class.public_send(method, url,
        headers: headers, body: bytes, timeout: 30, verify: true, follow_redirects: false)
      unless response.code.between?(200, 299)
        type = [ 401, 403 ].include?(response.code) ? :unauthorized : :http_error
        raise BunqError.new(type, http_status: response.code)
      end

      payload = JSON.parse(response.body)
      unless payload.is_a?(Hash) && payload["Response"].is_a?(Array) && payload["Response"].all? { |row| row.is_a?(Hash) }
        raise BunqError.new(:parse_error)
      end
      key = installation ? object(payload, "ServerPublicKey").fetch("server_public_key") : bunq_item.server_public_key
      signature = Base64.strict_decode64(response.headers.fetch("x-bunq-server-signature"))
      unless OpenSSL::PKey::RSA.new(key).verify("SHA256", signature, response.body)
        raise BunqError.new(:invalid_signature)
      end
      payload
    rescue BunqError
      raise
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError
      raise BunqError.new(:parse_error), cause: nil
    rescue OpenSSL::PKey::PKeyError, OpenSSL::OpenSSLError
      raise BunqError.new(:invalid_signature), cause: nil
    rescue SocketError, SystemCallError, Timeout::Error, IOError
      raise BunqError.new(:network_error), cause: nil
    end

    def authenticated_get(url)
      request(:get, url, token: @session_token)
    rescue BunqError => error
      raise unless error.http_status == 401

      authenticate!(force: true)
      request(:get, url, token: @session_token)
    end

    def fetch_pages(path)
      resource = URI.join(BASE_URLS.fetch(bunq_item.environment), path)
      url = "#{resource}?count=200"
      seen = Set.new
      rows = []
      loop do
        raise BunqError.new(:pagination_cycle) unless seen.add?(url)

        payload = authenticated_get(url)
        rows.concat(payload.fetch("Response"))
        pagination = payload["Pagination"]
        raise BunqError.new(:parse_error) unless pagination.nil? || pagination.is_a?(Hash)

        older = pagination&.[]("older_url")
        break if older.nil?

        raise BunqError.new(:invalid_url) unless older.is_a?(String) && older.present?

        uri = URI.join(resource.to_s, older)
        unless uri.scheme == "https" && uri.host == resource.host && uri.port == 443 &&
            uri.userinfo.nil? && uri.fragment.nil? && uri.path == resource.path
          raise BunqError.new(:invalid_url)
        end
        URI.decode_www_form(uri.query.to_s).each do |key, value|
          next unless key == "count"
          raise BunqError.new(:invalid_url) unless value.match?(/\A[0-9]+\z/) && value.to_i.between?(1, 200)
        end
        url = uri.to_s
      end
      rows
    rescue URI::InvalidURIError, ArgumentError
      raise BunqError.new(:invalid_url), cause: nil
    end
end
