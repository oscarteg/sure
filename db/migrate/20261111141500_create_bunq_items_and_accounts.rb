class CreateBunqItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :bunq_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.text :api_key, null: false
      t.string :environment, null: false, default: "production"
      t.string :user_id
      t.text :private_key
      t.text :installation_token
      t.text :server_public_key
      t.text :device_id
      t.string :institution_id, default: "bunq"
      t.string :institution_name, default: "bunq"
      t.string :institution_domain, default: "bunq.com"
      t.string :institution_url, default: "https://bunq.com"
      t.string :institution_color
      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.boolean :pending_account_setup, null: false, default: false
      t.date :sync_start_date
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload
      t.timestamps
    end
    add_index :bunq_items, :status

    create_table :bunq_accounts, id: :uuid do |t|
      t.references :bunq_item, null: false, foreign_key: true, type: :uuid
      t.string :account_id, null: false
      t.string :name, null: false
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider, default: "bunq"
      t.boolean :ignored, null: false, default: false
      t.date :sync_start_date
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.timestamps
    end
    add_index :bunq_accounts, [ :bunq_item_id, :account_id ], unique: true
  end
end
