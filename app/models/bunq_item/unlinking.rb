module BunqItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    bunq_accounts.map do |provider_account|
      links = AccountProvider.joins(:account).where(provider: provider_account, accounts: { family_id: family_id })
      result = { provider_account_id: provider_account.id, name: provider_account.name, provider_link_ids: links.pluck(:id) }
      unless dry_run
        transaction do
          links.each do |link|
            link.holdings.update_all(account_provider_id: nil)
            link.destroy!
          end
        end
      end
      result
    end
  end
end
