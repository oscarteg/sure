class BunqItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_bunq_item, only: %i[update destroy sync setup_accounts complete_account_setup]

  def create
    @bunq_item = Current.family.bunq_items.build(bunq_item_params)
    @bunq_item.name = t("bunq_items.provider_panel.default_connection_name") if @bunq_item.name.blank?

    if @bunq_item.save
      @bunq_item.sync_later
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("bunq", alert: @bunq_item.errors.full_messages.join(", "))
    end
  end

  def update
    attributes = bunq_item_params.except(:environment)
    attributes = attributes.except(:api_key) if attributes[:api_key].blank?
    attributes[:status] = :good if attributes[:api_key].present?

    if @bunq_item.with_lock { @bunq_item.update(attributes) }
      render_provider_panel("bunq", notice: t(".success"))
    else
      render_provider_panel("bunq", alert: @bunq_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    results = @bunq_item.unlink_all!(dry_run: false)
    if results.any? { |result| result[:error].present? }
      capture_failure("bunq disconnect failed")
      return redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
    end

    @bunq_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue StandardError => error
    capture_failure("bunq disconnect failed", error)
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def sync
    @bunq_item.sync_later unless @bunq_item.syncing?
    return render_provider_panel("bunq", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    redirect_to accounts_path, notice: t("settings.providers.sync_provider_in_progress"), status: :see_other
  end

  def setup_accounts
    refresh_accounts
    @bunq_accounts = @bunq_item.bunq_accounts.needs_setup.order(:name)
  end

  def complete_account_setup
    choices = params[:account_types]
    unless choices.is_a?(ActionController::Parameters)
      return redirect_to setup_accounts_bunq_item_path(@bunq_item), alert: t("bunq_items.link_failed")
    end

    created = 0
    BunqAccount.transaction do
      @bunq_item.bunq_accounts.where(id: choices.keys, account_status: "ACTIVE").order(:id).each do |bunq_account|
        bunq_account.with_lock do
          next if bunq_account.account_provider.present?

          case choices[bunq_account.id.to_s]
          when "skip"
            bunq_account.update!(ignored: true)
          when "Depository"
            create_and_link_account(bunq_account)
            created += 1
          end
        end
      end
      update_setup_status
    end
    @bunq_item.sync_later if created.positive?
    redirect_to accounts_path, notice: t(".success", count: created), status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotSaved => error
    capture_failure("bunq account setup failed", error)
    redirect_to setup_accounts_bunq_item_path(@bunq_item), alert: t("bunq_items.link_failed"), status: :see_other
  end

  def select_accounts
    @bunq_item = requested_bunq_item
    @return_to = safe_return_to_path
    refresh_accounts
    @bunq_accounts = @bunq_item.bunq_accounts.unlinked.where(account_status: "ACTIVE").order(:name)
    render layout: false
  end

  def link_accounts
    @bunq_item = requested_bunq_item
    unless params[:accountable_type].blank? || params[:accountable_type] == "Depository"
      return redirect_to accounts_path, alert: t("bunq_items.unsupported_account")
    end

    created = 0
    BunqAccount.transaction do
      @bunq_item.bunq_accounts.where(id: Array(params[:account_ids]).compact_blank, account_status: "ACTIVE").order(:id).each do |bunq_account|
        bunq_account.with_lock do
          next if bunq_account.account_provider.present?

          create_and_link_account(bunq_account)
          created += 1
        end
      end
      update_setup_status
    end

    if created.positive?
      @bunq_item.sync_later
      redirect_to safe_return_to_path || accounts_path, notice: t("bunq_items.complete_account_setup.success", count: created), status: :see_other
    else
      redirect_to select_accounts_bunq_items_path(bunq_item_id: @bunq_item.id), alert: t("bunq_items.link_failed"), status: :see_other
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotSaved => error
    capture_failure("bunq account linking failed", error)
    redirect_to accounts_path, alert: t("bunq_items.link_failed"), status: :see_other
  end

  def select_existing_account
    @bunq_item = requested_bunq_item
    @account = Current.family.accounts.accessible_by(Current.user).find(params[:account_id])
    if @account.linked? || @account.accountable_type != "Depository"
      return frame_redirect_to accounts_path, alert: t("bunq_items.unsupported_account")
    end

    @return_to = safe_return_to_path
    refresh_accounts
    @bunq_accounts = @bunq_item.bunq_accounts.unlinked.where(currency: @account.currency, account_status: "ACTIVE").order(:name)
    render :select_accounts, layout: false
  end

  def link_existing_account
    @bunq_item = requested_bunq_item
    account = Current.family.accounts.accessible_by(Current.user).find(params[:account_id])
    bunq_account = @bunq_item.bunq_accounts.where(account_status: "ACTIVE").find(params[:bunq_account_id])
    linked = false

    account.with_lock do
      bunq_account.with_lock do
        if account.unlinked? && account.accountable_type == "Depository" &&
            account.currency == bunq_account.currency && bunq_account.account_provider.blank?
          AccountProvider.create!(account: account, provider: bunq_account)
          bunq_account.update!(ignored: false)
          update_setup_status
          linked = true
        end
      end
    end

    unless linked
      return redirect_to accounts_path, alert: t("bunq_items.unsupported_account"), status: :see_other
    end

    @bunq_item.sync_later
    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name), status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotSaved => error
    capture_failure("bunq existing account linking failed", error)
    redirect_to accounts_path, alert: t("bunq_items.link_failed"), status: :see_other
  end

  private
    def set_bunq_item
      @bunq_item = Current.family.bunq_items.active.find(params[:id])
    end

    def requested_bunq_item
      Current.family.bunq_items.active.find(params[:bunq_item_id])
    end

    def bunq_item_params
      params.require(:bunq_item).permit(:name, :api_key, :environment, :sync_start_date)
    end

    def refresh_accounts
      accounts = @bunq_item.bunq_provider.get_accounts
      BunqAccount.transaction do
        accounts.each do |data|
          @bunq_item.bunq_accounts.find_or_initialize_by(account_id: data.fetch("id").to_s)
            .upsert_bunq_snapshot!(data)
        end
      end
    rescue Provider::Bunq::BunqError => error
      capture_failure("bunq account discovery failed", error)
      @api_error = t("bunq_items.setup_accounts.api_error")
    end

    def create_and_link_account(bunq_account)
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: bunq_account.name,
          balance: bunq_account.current_balance || 0,
          cash_balance: bunq_account.current_balance || 0,
          currency: bunq_account.currency,
          accountable_type: "Depository",
          accountable_attributes: { subtype: bunq_account.suggested_subtype }
        },
        skip_initial_sync: true
      )
      AccountProvider.create!(account: account, provider: bunq_account)
      bunq_account.update!(ignored: false)
    end

    def update_setup_status
      @bunq_item.update!(pending_account_setup: @bunq_item.bunq_accounts.needs_setup.exists?)
    end

    def capture_failure(message, error = nil)
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "error", message: message,
        source: self.class.name, provider_key: "bunq", family: @bunq_item.family,
        metadata: { bunq_item_id: @bunq_item.id, error_class: error&.class&.name }
      )
    end

    def safe_return_to_path
      return_to = params[:return_to].to_s.strip
      return unless return_to.start_with?("/")
      return if return_to[1] == "/" || return_to.include?("\\") || return_to.match?(/[[:cntrl:]]/)
      return if return_to.match?(%r{\A/%(?:2f|5c)}i)

      uri = URI.parse(return_to)
      return unless uri.relative?

      Rails.application.routes.recognize_path(uri.path, method: :get)
      return_to
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end
end
