class Provider::BunqAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BunqAccount", self)

  def self.supported_account_types
    %w[Depository]
  end

  def self.connection_item_class
    BunqItem
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_bunq?

    family.bunq_items.active.ordered.select(&:credentials_configured?).map do |item|
      {
        key: "bunq_#{item.id}",
        name: item.name,
        description: I18n.t("providers.bunq.description"),
        can_connect: true,
        new_account_path: ->(accountable_type, return_to) {
          Rails.application.routes.url_helpers.select_accounts_bunq_items_path(
            bunq_item_id: item.id, accountable_type: accountable_type, return_to: return_to
          )
        },
        existing_account_path: ->(account_id) {
          Rails.application.routes.url_helpers.select_existing_account_bunq_items_path(
            bunq_item_id: item.id, account_id: account_id
          )
        }
      }
    end
  end

  def self.build_provider(family: nil, bunq_item_id: nil)
    return nil unless family

    items = BunqItem.active.where(family_id: family.id)
    item = bunq_item_id.present? ? items.find_by(id: bunq_item_id) : items.ordered.find(&:credentials_configured?)
    Provider::Bunq.new(item) if item&.credentials_configured?
  end

  def provider_name
    "bunq"
  end

  def item
    provider_account.bunq_item
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_bunq_item_path(item)
  end

  def institution_name
    "bunq"
  end

  def institution_domain
    "bunq.com"
  end

  def institution_url
    "https://bunq.com"
  end

  def institution_color
    item.institution_color
  end
end
