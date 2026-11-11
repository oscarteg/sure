class BunqItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key
    encrypts :private_key
    encrypts :installation_token
    encrypts :server_public_key
    encrypts :device_id
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :bunq_accounts, dependent: :destroy
  has_many :accounts, through: :bunq_accounts

  validates :name, :api_key, presence: true
  validates :environment, inclusion: { in: Provider::Bunq::BASE_URLS.keys }
  validate :environment_cannot_change_with_accounts
  before_update :reset_installation_on_credential_change

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    api_key.present?
  end

  def import_latest_bunq_data
    BunqItem::Importer.new(self, bunq_provider: bunq_provider).import
  end

  def process_accounts
    provider_account = nil
    transaction do
      processable_accounts.map do |row|
        provider_account = row
        BunqAccount::Processor.new(provider_account).process
        { bunq_account_id: provider_account.id, success: true }
      end
    end
  rescue StandardError => error
    # Capture after rollback so the diagnostic survives the failed import.
    capture_sync_error(error, provider_account: provider_account)
    raise
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    processable_accounts.map do |provider_account|
      account = provider_account.current_account
      account.sync_later(parent_sync: parent_sync, window_start_date: window_start_date, window_end_date: window_end_date)
      { account_id: account.id, success: true }
    end
  end

  def has_completed_initial_setup?
    accounts.exists?
  end

  def linked_accounts_count
    bunq_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    bunq_accounts.needs_setup.count
  end

  def total_accounts_count
    bunq_accounts.count
  end

  def sync_status_summary
    "#{linked_accounts_count}/#{total_accounts_count}"
  end

  def institution_display_name
    institution_name.presence || "bunq"
  end

  def connected_institutions
    [ { "name" => "bunq", "domain" => "bunq.com" } ]
  end

  def institution_summary
    institution_display_name
  end

  def processable_accounts
    bunq_accounts.where(ignored: false, account_status: "ACTIVE").joins(:account).merge(Account.visible)
  end

  def capture_sync_error(error, provider_account: nil)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "bunq synchronization failed",
      source: self.class.name,
      provider_key: "bunq",
      family: family,
      account_provider: provider_account&.account_provider,
      metadata: { bunq_item_id: id, bunq_account_id: provider_account&.id, error_class: error.class.name }
    )
  end

  private

    def environment_cannot_change_with_accounts
      if persisted? && will_save_change_to_environment? && bunq_accounts.exists?
        errors.add(:environment, :invalid)
      end
    end

    def reset_installation_on_credential_change
      return unless will_save_change_to_api_key? || will_save_change_to_environment?

      self.private_key = self.installation_token = self.server_public_key = self.device_id = nil
      # Keep user_id on key rotation so a different bunq user cannot reuse links.
      self.user_id = nil if will_save_change_to_environment?
    end
end
