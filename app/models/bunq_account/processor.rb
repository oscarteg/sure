class BunqAccount::Processor
  def initialize(bunq_account)
    @bunq_account = bunq_account
  end

  def process
    account = @bunq_account.current_account
    return unless account && !@bunq_account.ignored? && @bunq_account.account_status == "ACTIVE"
    raise Provider::Bunq::BunqError.new(:family_mismatch) unless account.family_id == @bunq_account.bunq_item.family_id

    account.transaction do
      @bunq_account.raw_transactions_payload.to_a.each do |payment|
        BunqEntry::Processor.new(payment, bunq_account: @bunq_account).process
      end
      account.update!(balance: @bunq_account.current_balance, cash_balance: @bunq_account.current_balance, currency: @bunq_account.currency)
    end
  rescue StandardError => error
    @bunq_account.bunq_item.capture_sync_error(error, provider_account: @bunq_account)
    raise Provider::Bunq::BunqError.new(:processing_error), cause: nil
  end
end
