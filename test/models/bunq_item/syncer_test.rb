require "test_helper"

class BunqItem::SyncerTest < ActiveSupport::TestCase
  test "failed import cannot advance successful sync state or process stale history" do
    item = bunq_items(:one)
    sync = item.syncs.create!
    item.expects(:import_latest_bunq_data).raises(Provider::Bunq::BunqError.new(:network_error))
    item.expects(:process_accounts).never
    item.expects(:schedule_account_syncs).never
    DebugLogEntry.stubs(:capture)
    assert_raises(Provider::Bunq::BunqError) { BunqItem::Syncer.new(item).perform_sync(sync) }
    assert item.reload.requires_update?
    assert_nil item.last_synced_at
    assert_nil sync.reload.completed_at
  end
end
