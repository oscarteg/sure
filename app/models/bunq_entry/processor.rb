class BunqEntry::Processor
  def initialize(payment, bunq_account:)
    @payment = payment
    @bunq_account = bunq_account
  end

  def process
    account = @bunq_account.current_account
    return unless account
    raise Provider::Bunq::BunqError.new(:family_mismatch) unless account.family_id == @bunq_account.bunq_item.family_id

    id = @payment.fetch("id").to_s
    amount = BigDecimal(@payment.fetch("amount").fetch("value"))
    currency = @payment.fetch("amount").fetch("currency")
    date = Date.iso8601(@payment.fetch("created").to_s.split.first)
    unless id.match?(/\A[0-9]+\z/) && amount.finite? && Money::Currency.all.key?(currency.to_s.downcase)
      raise Provider::Bunq::BunqError.new(:parse_error)
    end
    counterparty = @payment.dig("counterparty_alias", "display_name").presence || @payment.dig("counterparty_alias", "label_monetary_account", "display_name").presence
    description = @payment["description"]
    name = [ counterparty, description ].compact_blank.map { |text| text.to_s.squish }.uniq.join(" - ")
    metadata = @payment.slice("id", "type", "sub_type", "description", "counterparty_alias", "alias", "balance_after_mutation", "amount_local", "amount_billing", "exchange_rate")
    local = @payment["amount_local"]
    if local.is_a?(Hash) && local["currency"].present? && local["currency"] != currency
      foreign_amount = BigDecimal(local.fetch("value"))
      raise Provider::Bunq::BunqError.new(:parse_error) unless foreign_amount.finite? && Money::Currency.all.key?(local["currency"].to_s.downcase)

      metadata.merge!("fx_from" => local["currency"], "fx_amount" => foreign_amount.abs.to_s("F"))
    end
    Account::ProviderImportAdapter.new(account).import_transaction(
      external_id: id, amount: -amount, currency: currency, date: date,
      name: name.presence || I18n.t("transactions.unknown_name"),
      source: "bunq", extra: { "bunq" => metadata },
      replace_extra_namespaces: [ "bunq" ],
      name_extra_keys: { "bunq" => %w[description counterparty_alias] }
    )
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::Bunq::BunqError.new(:parse_error), cause: nil
  end
end
