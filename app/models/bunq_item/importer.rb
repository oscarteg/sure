class BunqItem::Importer
  def initialize(bunq_item, bunq_provider:)
    @bunq_item = bunq_item
    @bunq_provider = bunq_provider
  end

  def import
    provider_account = nil
    raise Provider::Bunq::BunqError.new(:configuration_error) unless @bunq_provider

    snapshots = @bunq_provider.get_accounts
    transactions = {}
    snapshots.each do |snapshot|
      provider_account = @bunq_item.bunq_accounts.find_by(account_id: snapshot.fetch("id").to_s)
      next unless provider_account&.current_account && !provider_account.ignored?

      transactions[snapshot.fetch("id").to_s] = @bunq_provider.get_transactions(
        snapshot.fetch("id").to_s, start_date: provider_account.sync_start_date || @bunq_item.sync_start_date
      )
    rescue StandardError => error
      @bunq_item.capture_sync_error(error, provider_account: provider_account)
      raise Provider::Bunq::BunqError.new(:import_error), cause: nil
    end

    # Stage every page before replacing any snapshot. Never persist partial history.
    @bunq_item.transaction do
      @bunq_item.update!(raw_payload: snapshots)
      @bunq_item.bunq_accounts.where.not(account_id: snapshots.map { |snapshot| snapshot.fetch("id").to_s })
        .update_all(account_status: "INACTIVE")
      snapshots.each do |snapshot|
        provider_account = @bunq_item.bunq_accounts.find_or_initialize_by(account_id: snapshot.fetch("id").to_s)
        provider_account.upsert_bunq_snapshot!(snapshot)
        if transactions.key?(provider_account.account_id)
          provider_account.update!(raw_transactions_payload: transactions.fetch(provider_account.account_id))
        end
      end
    end
    { success: true, accounts_imported: snapshots.size, transactions_imported: transactions.values.sum(&:size) }
  rescue StandardError => error
    @bunq_item.capture_sync_error(error, provider_account: provider_account)
    raise Provider::Bunq::BunqError.new(:import_error), cause: nil
  end
end
