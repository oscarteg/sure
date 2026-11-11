module Family::BunqConnectable
  extend ActiveSupport::Concern

  included do
    has_many :bunq_items, dependent: :destroy
  end

  def can_connect_bunq?
    true
  end

  def has_bunq_credentials?
    bunq_items.active.any?(&:credentials_configured?)
  end
end
