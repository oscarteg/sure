class BunqAccount < ApplicationRecord
  include Encryptable

  INSTITUTION_NAME = "bunq".freeze
  INSTITUTION_DOMAIN = "bunq.com".freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :bunq_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, :account_id, presence: true
  validates :account_id, uniqueness: { scope: :bunq_item_id }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :needs_setup, -> { unlinked.where(ignored: false, account_status: "ACTIVE") }

  def current_account
    account
  end

  def suggested_account_type
    "Depository" if Provider::Bunq::ACCOUNT_TYPES.include?(account_type)
  end

  def suggested_subtype
    return unless suggested_account_type

    account_type == "MonetaryAccountSavings" ? "savings" : "checking"
  end

  def upsert_bunq_snapshot!(snapshot)
    balance = BigDecimal(snapshot.fetch("balance").fetch("value"))
    currency = snapshot.fetch("currency")
    unless balance.finite? && Money::Currency.all.key?(currency.to_s.downcase)
      raise Provider::Bunq::BunqError.new(:parse_error)
    end
    update!(
      account_id: snapshot.fetch("id").to_s,
      name: snapshot["description"].presence || INSTITUTION_NAME,
      currency: currency,
      current_balance: balance,
      account_status: snapshot.fetch("status"),
      account_type: snapshot.fetch("account_type"),
      provider: "bunq",
      institution_metadata: { name: INSTITUTION_NAME, domain: INSTITUTION_DOMAIN },
      raw_payload: snapshot
    )
  rescue KeyError, ArgumentError, TypeError
    raise Provider::Bunq::BunqError.new(:parse_error), cause: nil
  end
end
