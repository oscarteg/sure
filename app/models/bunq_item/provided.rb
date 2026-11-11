module BunqItem::Provided
  extend ActiveSupport::Concern

  def bunq_provider
    Provider::Bunq.new(self) if credentials_configured?
  end

  def syncer
    BunqItem::Syncer.new(self)
  end
end
