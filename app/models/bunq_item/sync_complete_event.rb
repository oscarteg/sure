class BunqItem::SyncCompleteEvent
  def initialize(bunq_item)
    @bunq_item = bunq_item
  end

  def broadcast
    @bunq_item.accounts.each(&:broadcast_sync_complete)
    @bunq_item.family.broadcast_sync_complete
  end
end
