class BunqItem::Syncer
  include SyncStats::Collector

  def initialize(bunq_item)
    @bunq_item = bunq_item
  end

  def perform_sync(sync)
    @bunq_item.import_latest_bunq_data
    collect_setup_stats(sync, provider_accounts: @bunq_item.bunq_accounts)
    @bunq_item.update!(pending_account_setup: @bunq_item.bunq_accounts.needs_setup.exists?)
    mark_import_started(sync)
    @bunq_item.process_accounts
    @bunq_item.schedule_account_syncs(
      parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date
    )
    collect_transaction_stats(sync, account_ids: @bunq_item.processable_accounts.filter_map { |row| row.current_account&.id }, source: "bunq")
    @bunq_item.update!(status: :good)
    collect_health_stats(sync, errors: nil)
  rescue StandardError => error
    @bunq_item.capture_sync_error(error)
    @bunq_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: "bunq synchronization failed", category: "sync_error" } ])
    raise Provider::Bunq::BunqError.new(:sync_error), cause: nil
  end

  def perform_post_sync
  end
end
