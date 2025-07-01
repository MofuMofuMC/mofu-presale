module presale::presale {
    use aptos_framework::timestamp;
    use aptos_framework::aptos_account::{Self};
    use std::signer;
    use std::vector;
    use std::option::{Self};
    use std::string::{Self};
    use aptos_framework::event::{Self};
    use aptos_std::table::{Self, Table};
    use presale::whitelist::{Self};
    use presale::referral::{Self};
    use presale::whitelist_nft::{Self};
    use aptos_framework::object::{Self, Object, ObjectCore};
    use aptos_framework::fungible_asset::{Self};
    #[test_only]
    use aptos_framework::primary_fungible_store;

    #[test_only]
    use aptos_framework::aptos_coin::{Self, AptosCoin};

    #[test_only]
    use aptos_framework::coin;

    #[test_only]
    use aptos_framework::account;

    // === Constants ===
    const STAGE_NONE: u64 = 0;
    const STAGE_PRIVATE_SALE: u64 = 1;
    const STAGE_GTD_WL: u64 = 2;
    const STAGE_FCFS_WL: u64 = 3;
    const STAGE_PUBLIC: u64 = 4;

    // === Structs ===
    struct LaunchpadConfig has key {
        treasury_addr: address,
        admin: address,
        accepted_coin_ids: vector<address>,
        stage: u64,
        presale_configs: vector<PresaleStage>
    }

    struct PresaleStage has store {
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64,
        max_quantity_per_wallet: u64
    }

    struct LaunchpadState has key {
        total_sold: u64,
        current_sold: u64
    }

    struct Payments has key {
        payments: Table<address, vector<Payment>>
    }

    struct Payment has copy, drop, store {
        buyer: address,
        quantity: u64,
        amount: u64,
        timestamp: u64,
        code: option::Option<string::String>
    }

    // === Errors ===
    const ESOLD_OUT: u64 = 1; // Presale is sold out
    const ENOT_AUTHORIZED: u64 = 2; // User is not authorized for this operation
    const EUNSUPPORTED_COIN_TYPE: u64 = 3; // Coin type not accepted for payment
    const EPAYMENT_AMOUNT_INVALID: u64 = 4; // Payment amount is invalid
    const EITEM_QUANTITY_INVALID: u64 = 5; // Invalid number of items requested
    const EOUTSIDE_PRESALE_PERIOD: u64 = 6; // Current time is not within presale period
    const EINVALID_TIME_RANGE: u64 = 7; // Start time must be before end time
    const EWRONG_STAGE_NOT_PRESALE: u64 = 8; // Current stage is not the presale stage
    const EWRONG_STAGE_NOT_WHITELIST: u64 = 9; // Current stage is not the whitelist stage
    const ESTAGE_INDEX_OUT_OF_RANGE: u64 = 10; // Stage index is out of valid range
    const EUSER_ALREADY_PURCHASED: u64 = 11; // User has already purchased items
    const EREFERRAL_CODE_LENGTH_INVALID: u64 = 12; // Referral code length is invalid
    const EUSER_NOT_QUALIFIED_FOR_REFERRAL: u64 = 13; // User does not qualify to create a referral
    const ECOIN_TYPE_ALREADY_ACCEPTED: u64 = 14; // Coin type already exists in accepted list
    const EWRONG_STAGE_NOT_PUBLIC: u64 = 15; // Current stage is not the public sale stage
    // === Constants ===
    const DEFAULT_MAX_PRESALE_SIZE: u64 = 1500;
    const DEFAULT_SALE_PRICE: u64 = 1000000;
    const MAX_QUANTITY_PER_PURCHASE: u64 = 5;
    // Define the accepted coin metadata address for purchases
    const ACCEPTED_COIN_METADATA_ID: address =
        @0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832;

    // ======== Events ========

    #[event]
    struct PurchasedEvent has drop, store {
        buyer: address,
        quantity: u64,
        amount: u64,
        timestamp: u64,
        code: option::Option<string::String>
    }

    // Initialize the presale module with default configurations
    fun init_module(admin: &signer) {
        let launchpad_config = LaunchpadConfig {
            treasury_addr: @treasury_addr,
            // Initialize with default accepted coin (empty vector)
            accepted_coin_ids: vector::empty<address>(),
            admin: @admin_addr,
            stage: STAGE_PRIVATE_SALE,
            presale_configs: vector::empty<PresaleStage>()
        };

        // Add default accepted coin
        // vector::push_back(
        //     &mut launchpad_config.accepted_coin_ids, ACCEPTED_COIN_METADATA_ID
        // );

        let presale_config = PresaleStage {
            presale_max_size: DEFAULT_MAX_PRESALE_SIZE,
            presale_price: DEFAULT_SALE_PRICE,
            presale_start_time: 0,
            presale_end_time: 0,
            max_quantity_per_wallet: 0
        };
        vector::push_back(&mut launchpad_config.presale_configs, presale_config);
        move_to(admin, launchpad_config);

        let launchpad_state = LaunchpadState { total_sold: 0, current_sold: 0 };
        move_to(admin, launchpad_state);
        let payments = Payments {
            payments: table::new<address, vector<Payment>>()
        };
        move_to(admin, payments);

        whitelist::init_whitelist_config(admin);
        whitelist_nft::init_whitelist_nft_config(admin);
        referral::init_referral_registry(admin);
    }

    // === Public-Entry Functions ===
    // Update presale stage configuration and set current stage
    public entry fun update_presale_stage(
        admin: &signer,
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64,
        max_quantity_per_wallet: u64,
        stage: u64
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();

        let admin_addr = signer::address_of(admin);
        let launchpad_config = borrow_launchpad_config_mut();

        assert!(is_admin(launchpad_config, admin_addr), ENOT_AUTHORIZED);
        assert!(presale_start_time < presale_end_time, EINVALID_TIME_RANGE); // Start time must be before end time

        launchpad_config.stage = stage; // Set stage to presale
        add_or_update_stage(
            admin,
            presale_max_size,
            presale_price,
            presale_start_time,
            presale_end_time,
            max_quantity_per_wallet,
            stage
        );
    }

    // Reset current sold count to zero (admin only)
    public entry fun reset_current_sold(admin: &signer) acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let launchpad_config = borrow_launchpad_config_mut();
        assert!(is_admin(launchpad_config, admin_addr), ENOT_AUTHORIZED);

        let launchpad_state = borrow_state_mut();
        launchpad_state.current_sold = 0; // Reset current sold count
    }

    // Add or update stage configuration in the presale configs vector
    fun add_or_update_stage(
        _admin: &signer,
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64,
        max_quantity_per_wallet: u64,
        stage: u64
    ) acquires LaunchpadConfig {
        // assert!(presale_start_time < presale_end_time, ESTART_TIME_AFTER_END_TIME); // Start time must be before end time

        let num_stages = get_num_of_presale_stages();
        let launchpad_config = borrow_launchpad_config_mut();
        if (stage == num_stages) {
            let presale_stage = PresaleStage {
                presale_max_size,
                presale_price,
                presale_start_time,
                presale_end_time,
                max_quantity_per_wallet
            };
            vector::push_back(&mut launchpad_config.presale_configs, presale_stage);
        } else {
            let stage = vector::borrow_mut(&mut launchpad_config.presale_configs, stage);
            stage.presale_max_size = presale_max_size;
            stage.presale_price = presale_price;
            stage.presale_start_time = presale_start_time;
            stage.max_quantity_per_wallet = max_quantity_per_wallet;
            stage.presale_end_time = presale_end_time;
        };
    }

    // Sets the treasury address for the launchpad.
    public entry fun set_treasury(
        admin: &signer, new_treasury_addr: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        aptos_account::assert_account_is_registered_for_apt(new_treasury_addr);
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        config.treasury_addr = new_treasury_addr;
    }

    // Adds a user to the whitelist with a maximum quantity per purchase.
    public entry fun add_to_whitelist(admin: &signer, user_addr: address) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let config = borrow_launchpad_config_mut();
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        whitelist::add_to_whitelist(user_addr, MAX_QUANTITY_PER_PURCHASE);
    }

    // Add NFT to whitelist for genesis holders
    public entry fun add_to_nft_whitelist(admin: &signer, nft_id: address) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let config = borrow_launchpad_config_mut();
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        whitelist_nft::add_nft_to_whitelist(nft_id);
    }

    // Remove NFT from whitelist
    public entry fun remove_from_nft_whitelist(
        admin: &signer, nft_id: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let config = borrow_launchpad_config_mut();
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        whitelist_nft::remove_nft_from_whitelist(nft_id);
    }

    // Removes a user from the whitelist.
    public entry fun remove_from_whitelist(
        admin: &signer, user_addr: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let config = borrow_launchpad_config_mut();
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        whitelist::remove_from_whitelist(user_addr);
    }

    // Transfer admin privileges to new address
    public entry fun set_admin(admin: &signer, new_admin: address) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        config.admin = new_admin;
    }

    // Set current active presale stage
    public entry fun set_stage(admin: &signer, stage: u64) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        assert!(
            stage < vector::length(&config.presale_configs),
            ESTAGE_INDEX_OUT_OF_RANGE
        );
        config.stage = stage;
    }

    // Adds a coin type to the accepted payment methods
    public entry fun add_accepted_coin_id(
        admin: &signer, coin_id: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        assert!(
            vector::contains(&config.accepted_coin_ids, &coin_id) == false,
            ECOIN_TYPE_ALREADY_ACCEPTED
        );

        vector::push_back(&mut config.accepted_coin_ids, coin_id);
    }

    // Removes a coin type from the accepted payment methods
    public entry fun remove_accepted_coin_id(
        admin: &signer, coin_id: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);

        // Check if the coin ID exists before attempting to remove it
        assert!(
            vector::contains(&config.accepted_coin_ids, &coin_id),
            EUNSUPPORTED_COIN_TYPE
        );

        // Remove the coin ID from the accepted coins list
        let (is_exist, index) = vector::index_of(&config.accepted_coin_ids, &coin_id);
        if (is_exist) {
            vector::remove(&mut config.accepted_coin_ids, index);
        }
    }

    public entry fun purchase(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        quantity: u64,
        code: option::Option<string::String>
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();

        assert_within_presale_period(launchpad_config);
        assert_not_sold_out(launchpad_config);
        assert_has_not_purchased(signer::address_of(sender));
        assert!(launchpad_config.stage > STAGE_FCFS_WL, EWRONG_STAGE_NOT_PUBLIC);

        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);
        assert_quantity_in_range(quantity, presale_stage.max_quantity_per_wallet);

        let launchpad_state = borrow_state();
        // Check if presale is sold out
        assert!(
            launchpad_state.current_sold + (quantity as u64)
                <= presale_stage.presale_max_size,
            ESOLD_OUT
        );

        if (option::is_some(&code)) {
            let code = option::extract(&mut code);
            referral::assert_referral_code_available(code);
            referral::increase_current_invites(
                signer::address_of(sender), code, quantity
            );
        };

        // Presale sold out
        let total_price = purchase_internal_with_asset(sender, metadata, quantity, code);

        event::emit(
            PurchasedEvent {
                buyer: signer::address_of(sender),
                quantity,
                amount: total_price,
                timestamp: timestamp::now_seconds(),
                code: code
            }
        );
    }

    // Purchases items during the presale using a referral code.
    public entry fun purchase_by_whitelist(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        quantity: u64,
        code: option::Option<string::String>
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();

        assert_within_presale_period(launchpad_config);
        assert_not_sold_out(launchpad_config);
        assert_has_not_purchased(signer::address_of(sender));

        assert!(
            launchpad_config.stage >= STAGE_GTD_WL
                && launchpad_config.stage <= STAGE_FCFS_WL,
            EWRONG_STAGE_NOT_WHITELIST
        );
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);

        assert_quantity_in_range(quantity, presale_stage.max_quantity_per_wallet);
        let launchpad_state = borrow_state();
        // Check if presale is sold out
        assert!(
            launchpad_state.current_sold + (quantity as u64)
                <= presale_stage.presale_max_size,
            ESOLD_OUT
        );

        if (option::is_some(&code)) {
            let code = option::extract(&mut code);
            referral::assert_referral_code_available(code);
            referral::increase_current_invites(
                signer::address_of(sender), code, quantity
            );
        };

        whitelist::decrease_whitelist_mint_amount(sender, quantity);
        

        // Presale sold out
        let total_price = purchase_internal_with_asset(sender, metadata, quantity, code);

        event::emit(
            PurchasedEvent {
                buyer: signer::address_of(sender),
                quantity,
                amount: total_price,
                timestamp: timestamp::now_seconds(),
                code: code
            }
        );
    }

    // Purchase NFTs during private sale with optional genesis NFT
    public entry fun purchase_by_private_sale(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        quantity: u64,
        genesis_object: option::Option<Object<ObjectCore>>
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();

        assert_within_presale_period(launchpad_config);
        assert_not_sold_out(launchpad_config);
        assert_quantity_in_range(quantity, MAX_QUANTITY_PER_PURCHASE);
        assert_has_not_purchased(signer::address_of(sender));
        assert_correct_stage(launchpad_config, STAGE_PRIVATE_SALE);

        let presale_config = get_stage_by_index(launchpad_config, STAGE_PRIVATE_SALE);
        // assert!(
        //     launchpad_config.stage == STAGE_PRIVATE_SALE,
        //     EWRONG_STAGE_NOT_PRESALE
        // );

        let launchpad_state = borrow_state();
        // Check if presale is sold out
        assert!(
            launchpad_state.current_sold + (quantity as u64)
                <= presale_config.presale_max_size,
            ESOLD_OUT
        ); // Presale sold out

        let total_price =
            purchase_internal_with_asset(sender, metadata, quantity, option::none());
        if (option::is_some(&genesis_object)) {
            // If genesis object is provided, mint whitelist NFT
            let genesis = option::extract(&mut genesis_object);
            let sender_addr = signer::address_of(sender);
            whitelist_nft::mark_nft_as_used(sender_addr, genesis);
        } else {
            whitelist::decrease_whitelist_mint_amount(sender, quantity);
        };

        // Emit event
        event::emit(
            PurchasedEvent {
                buyer: signer::address_of(sender),
                quantity,
                amount: total_price,
                timestamp: timestamp::now_seconds(),
                code: option::none()
            }
        );
    }

    // Create referral code after purchasing 3+ NFTs
    public entry fun create_referral_code(
        sender: &signer, code: string::String
    ) acquires Payments {
        let buyer = signer::address_of(sender);
        // Check code length is valid (between 4 and 30 characters)
        let code_length = string::length(&code);
        assert!(
            code_length >= 4 && code_length <= 30,
            EREFERRAL_CODE_LENGTH_INVALID
        );

        let payments = borrow_payments_mut();
        let user_payments =
            table::borrow_mut_with_default(
                &mut payments.payments, buyer, vector::empty<Payment>()
            );

        assert!(vector::length(user_payments) > 0, 0); // User has already purchased

        let user_payment = vector::borrow(user_payments, 0); // Ensure the user has no previous payments
        let quantity = user_payment.quantity;
        assert!(quantity > 2, EUSER_NOT_QUALIFIED_FOR_REFERRAL);

        let max_invites = {
            if (quantity <= 4) { 10 }
            else { 1000 }
        };
        referral::create_referral_code(sender, code, max_invites);
    }

    // === Private Functions ===
    // Transfer payment to treasury address
    fun pay_for_presale(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        amount: u64,
        treasury_addr: address
    ) {
        // let amount = fungible_asset::amount(&asset);
        assert!(amount > 0, EPAYMENT_AMOUNT_INVALID);
        // Transfer fungible asset to treasury

        aptos_account::transfer_fungible_assets(sender, metadata, treasury_addr, amount);
    }

    // Internal purchase logic with payment recording
    fun purchase_internal(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        quantity: u64,
        code: option::Option<string::String>
    ): u64 acquires Payments, LaunchpadState, LaunchpadConfig {
        let buyer = signer::address_of(sender);
        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);
        let total_price = presale_stage.presale_price * (quantity as u64);
        let launchpad_state = borrow_state_mut();
        pay_for_presale(
            sender,
            metadata,
            total_price,
            launchpad_config.treasury_addr
        );
        launchpad_state.current_sold = launchpad_state.current_sold + (quantity as u64);
        launchpad_state.total_sold = launchpad_state.total_sold + (quantity as u64);
        // Record the payment
        let payment = Payment {
            buyer,
            quantity,
            amount: total_price,
            timestamp: timestamp::now_seconds(),
            code
        };

        let payments = borrow_payments_mut();
        let user_payments =
            table::borrow_mut_with_default(
                &mut payments.payments, buyer, vector::empty<Payment>()
            );

        vector::push_back(user_payments, payment);

        total_price
    }

    // Internal purchase with asset validation and payment processing
    fun purchase_internal_with_asset(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        quantity: u64,
        code: option::Option<string::String>
    ): u64 acquires Payments, LaunchpadState, LaunchpadConfig {
        let buyer = signer::address_of(sender);
        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);

        // Verify asset type is accepted by checking metadata object address
        let metadata_object_address = object::object_address(&metadata);

        assert!(
            is_accepted_coin(launchpad_config, metadata_object_address),
            EUNSUPPORTED_COIN_TYPE
        );

        let total_amount = presale_stage.presale_price * (quantity as u64);

        pay_for_presale(
            sender,
            metadata,
            total_amount,
            launchpad_config.treasury_addr
        );

        let launchpad_state = borrow_state_mut();
        launchpad_state.current_sold = launchpad_state.current_sold + (quantity as u64);
        launchpad_state.total_sold = launchpad_state.total_sold + (quantity as u64);

        // Record the payment
        let payment = Payment {
            buyer,
            quantity,
            amount: total_amount,
            timestamp: timestamp::now_seconds(),
            code
        };

        let payments = borrow_payments_mut();
        let user_payments =
            table::borrow_mut_with_default(
                &mut payments.payments, buyer, vector::empty<Payment>()
            );

        vector::push_back(user_payments, payment);

        total_amount
    }

    // Get total number of configured presale stages
    fun get_num_of_presale_stages(): u64 acquires LaunchpadConfig {
        // assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        vector::length(&launchpad_config.presale_configs) as u64
    }

    //  === Public-View Functions ===
    // Get quantity of NFTs purchased by user
    #[view]
    public fun get_user_purchase_quantity(user: address): u64 acquires Payments {
        if (!exists<Payments>(@presale)) {
            return 0
        };

        let payments = borrow_payments();
        if (!table::contains(&payments.payments, user)) {
            return 0
        };

        let user_payments = table::borrow(&payments.payments, user);
        if (vector::is_empty(user_payments)) {
            return 0
        };

        // Return the quantity from the first payment
        // (users can only purchase once)
        let payment = vector::borrow(user_payments, 0);
        payment.quantity
    }

    // Get start and end time for specific stage
    #[view]
    public fun get_stage_period_by_index(stage: u64): (u64, u64) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        let stage = get_stage_by_index(launchpad_config, stage);
        (stage.presale_start_time, stage.presale_end_time)
    }

    // Get current active stage configuration
    #[view]
    public fun get_current_stage_config(): (u64, u64, u64, u64, u64) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        let stage = get_stage_by_index(launchpad_config, launchpad_config.stage);
        (
            stage.presale_max_size,
            stage.presale_price,
            stage.presale_start_time,
            stage.presale_end_time,
            stage.max_quantity_per_wallet
        )
    }

    // Get presale statistics (total sold, current sold)
    #[view]
    public fun get_presale_state(): (u64, u64) acquires LaunchpadState {
        assert_launchpad_config_exists();
        let launchpad_state = borrow_state();
        (launchpad_state.total_sold, launchpad_state.current_sold)
    }

    // Check if launchpad config exists at address
    #[view]
    public fun launchpad_config_exists(module_address: address): bool {
        exists<LaunchpadConfig>(module_address)
    }

    // Check if user has already purchased
    #[view]
    public fun has_purchased(buyer: address): bool acquires Payments {
        let payments = borrow_payments();
        table::contains(&payments.payments, buyer)
    }

    // Check if current stage is sold out
    #[view]
    public fun has_sold_out(): bool acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let launchpad_state = borrow_state();
        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);
        is_sold_out(launchpad_state.current_sold, presale_stage.presale_max_size)
    }

    // === Inline Functions ===
    // Check if a coin type is accepted
    inline fun is_accepted_coin(
        config: &LaunchpadConfig, coin_id: address
    ): bool {
        vector::contains(&config.accepted_coin_ids, &coin_id)
    }

    // Get stage configuration by index
    inline fun get_stage_by_index(
        launchpad_config: &LaunchpadConfig, index: u64
    ): &PresaleStage acquires LaunchpadConfig {
        assert!(
            index < vector::length(&launchpad_config.presale_configs),
            ESTAGE_INDEX_OUT_OF_RANGE
        );
        vector::borrow(&launchpad_config.presale_configs, index)
    }

    // Get immutable reference to launchpad config
    inline fun borrow_launchpad_config(): &LaunchpadConfig acquires LaunchpadConfig {
        borrow_global<LaunchpadConfig>(@presale)
    }

    // Get mutable reference to launchpad config
    inline fun borrow_launchpad_config_mut(): &mut LaunchpadConfig acquires LaunchpadConfig {
        borrow_global_mut<LaunchpadConfig>(@presale)
    }

    // Get immutable reference to launchpad state
    inline fun borrow_state(): &LaunchpadState acquires LaunchpadState {
        borrow_global<LaunchpadState>(@presale)
    }

    // Get mutable reference to launchpad state
    inline fun borrow_state_mut(): &mut LaunchpadState acquires LaunchpadState {
        borrow_global_mut<LaunchpadState>(@presale)
    }

    // Get immutable reference to payments table
    inline fun borrow_payments(): &Payments acquires Payments {
        let payments = borrow_global<Payments>(@presale);
        payments
    }

    // Get mutable reference to payments table
    inline fun borrow_payments_mut(): &mut Payments acquires Payments {
        let payments = borrow_global_mut<Payments>(@presale);
        payments
    }

    // Check if address has admin privileges
    inline fun is_admin(config: &LaunchpadConfig, addr: address): bool {
        if (config.admin == addr) { true }
        else { false }
    }

    // Assert caller has admin privileges
    inline fun assert_is_admin(addr: address) {
        let config = borrow_global<LaunchpadConfig>(@presale);
        assert!(is_admin(config, addr), ENOT_AUTHORIZED);
    }

    // Assert launchpad config resource exists
    inline fun assert_launchpad_config_exists() acquires LaunchpadConfig {
        assert!(
            exists<LaunchpadConfig>(@presale),
            ENOT_AUTHORIZED
        ); // Presale config not found
    }

    // Assert quantity is within valid range
    inline fun assert_quantity_in_range(quantity: u64, max_quantity: u64) {
        assert!(
            quantity > 0 && quantity <= max_quantity,
            EITEM_QUANTITY_INVALID
        ); // Invalid quantity
    }

    // Assert current stage matches expected stage
    inline fun assert_correct_stage(
        launchpad_config: &LaunchpadConfig, expected_stage: u64
    ) acquires LaunchpadConfig {
        // let launchpad_config = borrow_launchpad_config();
        assert!(
            launchpad_config.stage == expected_stage,
            EWRONG_STAGE_NOT_PRESALE
        ); // Current stage is not the expected stage
    }

    // Assert user hasn't purchased before
    inline fun assert_has_not_purchased(buyer: address) acquires Payments {
        let payments = borrow_payments();
        assert!(
            !table::contains(&payments.payments, buyer),
            EUSER_ALREADY_PURCHASED
        ); // User has already purchased
    }

    // Check if stage has reached maximum capacity
    inline fun is_sold_out(current_sold: u64, max_presale_size: u64): bool {
        current_sold >= max_presale_size
    }

    // Check if current time is within presale period
    inline fun is_within_presale_period(
        presale_start_time: u64, presale_end_time: u64
    ): bool {
        let now = timestamp::now_seconds();
        now >= presale_start_time && now <= presale_end_time
    }

    // Assert current time is within active presale period
    inline fun assert_within_presale_period(
        launchpad_config: &LaunchpadConfig
    ) {
        // let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);

        assert!(
            is_within_presale_period(
                presale_stage.presale_start_time,
                presale_stage.presale_end_time
            ),
            EOUTSIDE_PRESALE_PERIOD
        ); // Not in presale time
    }

    // Assert current stage is not sold out
    inline fun assert_not_sold_out(launchpad_config: &LaunchpadConfig) acquires LaunchpadState {
        let launchpad_state = borrow_state();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);

        assert!(
            !is_sold_out(launchpad_state.current_sold, presale_stage.presale_max_size),
            ESOLD_OUT
        ); // Presale is sold out
    }

    #[test_only]
    use std::debug;

    #[test_only]
    use aptos_framework::account::create_account_for_test;

    // Initialize testing environment with framework setup
    #[test_only]
    public fun init_module_for_test(
        aptos_framework: &signer, deployer: &signer, user: &signer
    ): (coin::BurnCapability<AptosCoin>, coin::MintCapability<AptosCoin>) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);

        // create a fake account (only for testing purposes)
        create_account_for_test(signer::address_of(deployer));
        create_account_for_test(signer::address_of(user));
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(1005); // Set a fixed time for testing

        (burn_cap, mint_cap)
    }

    // === Tests ===
    // Test complete presale flow from private sale to whitelist stages
    #[
        test(
            core = @0x1,
            owner = @presale,
            admin = @admin_addr,
            userA = @0xAA,
            userB = @0xBB,
            userC = @0xCC,
            userD = @0xDD,
            userE = @0xEE
        )
    ]
    fun test_end_2_end_flow_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        userA: &signer,
        userB: &signer,
        userC: &signer,
        userD: &signer,
        userE: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, userA);
        create_account_for_test(signer::address_of(owner));
        let (token_object, token_addr) =
            whitelist_nft::create_test_token_for_testing(owner);

        let userA_addr = signer::address_of(userA);
        let userB_addr = signer::address_of(userB);
        let userC_addr = signer::address_of(userC);
        let userD_addr = signer::address_of(userD);
        let userE_addr = signer::address_of(userE);

        let metadata = setup_testing_token(owner, userA_addr, 50000000);
        let metadata_addr = object::object_address(&metadata);

        // faucet some coins to users
        primary_fungible_store::transfer(userA, metadata, userB_addr, 10000000);
        primary_fungible_store::transfer(userA, metadata, userC_addr, 10000000);
        primary_fungible_store::transfer(userA, metadata, userD_addr, 10000000);
        primary_fungible_store::transfer(userA, metadata, userE_addr, 10000000);

        init_module(owner);
        add_accepted_coin_id(admin, metadata_addr);

        // transfer NFT to user B for private sale
        object::transfer(owner, token_object, userB_addr);

        // start private sale stage
        update_presale_stage(
            admin,
            10, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        add_to_whitelist(admin, userA_addr); // Add user A to whitelist
        add_to_nft_whitelist(admin, token_addr); // Add NFT to whitelist

        // user a
        purchase_by_private_sale(userA, metadata, 3, option::none());
        let code = string::utf8(b"ABCDE1234");
        create_referral_code(userA, code);

        let launchpad_state = borrow_state();
        assert!(launchpad_state.total_sold == 3, 0);
        assert!(launchpad_state.current_sold == 3, 0);

        // user b
        purchase_by_private_sale(userB, metadata, 5, option::some(token_object));

        timestamp::update_global_time_for_test_secs(10005); // Set a fixed time for testing

        // GTD WL stage
        update_presale_stage(
            admin,
            5, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            3,
            STAGE_GTD_WL // Set stage to whitelist
        );

        reset_current_sold(admin); // Reset current sold count
        let launchpad_state = borrow_state();
        assert!(launchpad_state.current_sold == 0, 0);
        // user c
        purchase_by_whitelist(userC, metadata, 3, option::some(code)); //
        let launchpad_state = borrow_state();
        assert!(launchpad_state.total_sold == 11, 0);
        assert!(launchpad_state.current_sold == 3, 0);

        // GTD WL stage
        update_presale_stage(
            admin,
            5, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            2,
            STAGE_FCFS_WL // Set stage to whitelist
        );

        reset_current_sold(admin); // Reset current sold count
        let launchpad_state = borrow_state();
        assert!(launchpad_state.current_sold == 0, 0);

        purchase_by_whitelist(userD, metadata, 2, option::some(code)); //
        let launchpad_state = borrow_state();
        assert!(launchpad_state.total_sold == 13, 0);
        assert!(launchpad_state.current_sold == 2, 0);

        // Public stage
        update_presale_stage(
            admin,
            5, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5,
            STAGE_PUBLIC // Set stage to whitelist
        );
        reset_current_sold(admin); // Reset current sold count
        purchase(userE, metadata, 4, option::none()); //

        let (max_invites, current_invites, current_sales) =
            referral::get_referral_stats(code);
        assert!(current_invites == 2, 0);
        assert!(max_invites == 10, 0); //
        assert!(current_sales == 5, 0); //

        let launchpad_state = borrow_state();
        assert!(launchpad_state.total_sold == 17, 0);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test successful private sale purchase
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    fun test_purchase_by_private_sale_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, user);

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            10, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5, // Set max quantity per wallet
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        add_to_whitelist(admin, user_addr); // Add user to whitelist
        let owner_addr = signer::address_of(owner);
        // User purchases 3 items
        purchase_by_private_sale(user, metadata, 3, option::none());

        let config = borrow_launchpad_config();
        let payments = borrow_payments();
        let user_payments = table::borrow(&payments.payments, user_addr);

        assert!(vector::length(user_payments) == 1, 0);

        let payment = vector::borrow(user_payments, 0);
        assert!(payment.quantity == 3, 0);
        assert!(payment.amount == 3000000, 0); // 3 * 100000000
        assert!(payment.buyer == user_addr, 0);

        // check the treasury balance
        assert!(
            primary_fungible_store::balance(config.treasury_addr, metadata) == 3000000,
            2
        );
        assert!(
            whitelist::is_user_eligible_for_whitelist_mint(user_addr) == 2,
            0
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test purchase rejection when exceeding maximum quantity
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_purchase_by_private_sale_over_max_quantity(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            100000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5, // Set max quantity per wallet
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        // Try to purchase 6 items (over MAX_QUANTITY_PER_PURCHASE = 5) - should fail
        purchase_by_private_sale(user, metadata, 6, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test prevention of multiple purchases by same user
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = EUSER_ALREADY_PURCHASED, location = Self)]
    fun test_purchase_by_private_sale_two_times(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, user);

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_to_whitelist(admin, user_addr); // Add user to whitelist
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        purchase_by_private_sale(user, metadata, 4, option::none());
        purchase_by_private_sale(user, metadata, 1, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test purchase rejection with insufficient token balance
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = 65540, location = fungible_asset)]
    fun test_purchase_by_private_sale_by_insufficient_balance(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, user);

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 500);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_to_whitelist(admin, user_addr); // Add user to whitelist
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        purchase_by_private_sale(user, metadata, 4, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test purchase rejection when exceeding stage capacity
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = ESOLD_OUT, location = Self)]
    fun test_purchase_by_private_sale_by_insufficient_mint_amount(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, user);

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 500);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_to_whitelist(admin, user_addr); // Add user to whitelist
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            3, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        purchase_by_private_sale(user, metadata, 4, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test purchase rejection for non-whitelisted users
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = 1, location = presale::whitelist)]
    fun test_purchase_by_private_sale_without_whitelist(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);

        timestamp::update_global_time_for_test_secs(10000); // Set a fixed time for testing
        let user_addr = signer::address_of(user);

        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        // Don't add user to whitelist
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000, // End time in the future
            5, // Set max quantity per wallet
            STAGE_PRIVATE_SALE // Set stage to presale
        );
        // Try to purchase without being whitelisted - should fail
        purchase_by_private_sale(user, metadata, 3, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test treasury address update functionality
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, new_treasury = @0x2
    )]
    fun test_set_treasury_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        new_treasury: &signer
    ) acquires LaunchpadConfig {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);

        let new_treasury_addr = signer::address_of(new_treasury);
        account::create_account_for_test(new_treasury_addr);
        coin::register<AptosCoin>(new_treasury);

        init_module(owner);
        set_treasury(admin, new_treasury_addr);

        let config = borrow_launchpad_config();
        assert!(config.treasury_addr == new_treasury_addr, 0);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test admin privilege transfer
    #[test(owner = @presale, admin = @admin_addr)]
    fun test_set_admin_ok(owner: &signer, admin: &signer) acquires LaunchpadConfig {
        init_module(owner);
        let new_admin = @0xA;
        set_admin(admin, new_admin);
        let config = borrow_launchpad_config();
        assert!(config.admin == new_admin, 0);
    }

    // Test prevention of admin actions by former admin
    #[test(owner = @presale)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_old_admin_cannot_set_admin_after_transfer(owner: &signer) acquires LaunchpadConfig {
        init_module(owner);
        let owner_addr = signer::address_of(owner);
        assert!(launchpad_config_exists(owner_addr), 0); // Presale config not found

        // Set new admin
        let new_admin = @0xA;
        set_admin(owner, new_admin);

        // Verify new admin is set
        let config = borrow_launchpad_config();
        assert!(config.admin == new_admin, 0);

        // Old admin tries to set another admin - should fail
        let another_admin = @0xB;
        set_admin(owner, another_admin); // This should abort with ENOT_AUTHORIZED
    }

    // Test rejection of admin actions by unauthorized users
    #[test(owner = @presale, normal_user = @0x123)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_normal_user_cannot_set_admin(
        owner: &signer, normal_user: &signer
    ) acquires LaunchpadConfig {
        init_module(owner);

        // Normal user tries to set admin - should fail
        let new_admin = @0xA;
        set_admin(normal_user, new_admin);
    }

    // Test rejection of treasury updates by unauthorized users
    #[test(
        core = @0x1, owner = @presale, normal_user = @0x123, treasury = @0x456
    )]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_normal_user_cannot_set_treasury(
        core: &signer,
        owner: &signer,
        normal_user: &signer,
        treasury: &signer
    ) acquires LaunchpadConfig {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);

        let treasury_addr = signer::address_of(treasury);
        account::create_account_for_test(treasury_addr);
        coin::register<AptosCoin>(treasury);

        init_module(owner);
        let owner_addr = signer::address_of(owner);
        assert!(launchpad_config_exists(owner_addr), 0);

        // Normal user tries to set treasury - should fail
        set_treasury(normal_user, treasury_addr);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test admin function calls before module initialization
    #[test(owner = @presale)]
    #[expected_failure(abort_code = ENOT_AUTHORIZED, location = Self)]
    fun test_set_admin_without_init(owner: &signer) acquires LaunchpadConfig {
        // Don't call init_module - try to set admin without initialization
        let new_admin = @0xA;
        set_admin(owner, new_admin);
    }

    // Test treasury function calls before module initialization
    #[test(core = @0x1, owner = @presale, treasury = @0x456)]
    #[expected_failure(abort_code = ENOT_AUTHORIZED, location = Self)]
    fun test_set_treasury_without_init(
        core: &signer, owner: &signer, treasury: &signer
    ) acquires LaunchpadConfig {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);

        let treasury_addr = signer::address_of(treasury);
        account::create_account_for_test(treasury_addr);
        coin::register<AptosCoin>(treasury);

        // Don't call init_module - try to set treasury without initialization
        set_treasury(owner, treasury_addr);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test purchase rejection outside presale time window
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = EOUTSIDE_PRESALE_PERIOD, location = Self)]
    fun test_purchase_by_private_sale_outside_presale_time(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);

        timestamp::update_global_time_for_test_secs(1); // Set time before presale starts
        let user_addr = signer::address_of(user);
        account::create_account_for_test(user_addr);
        coin::register<AptosCoin>(user);

        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);

        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );
        timestamp::update_global_time_for_test_secs(16000); // Set time before presale starts

        // Try to purchase before presale starts (current time: 5000, start: 10000) - should fail
        purchase_by_private_sale(user, metadata, 3, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test sold out status detection
    #[test(core = @0x1, owner = @presale, admin = @admin_addr)]
    fun test_has_sold_out_ok(
        core: &signer, owner: &signer, admin: &signer
    ) acquires LaunchpadConfig, LaunchpadState {
        timestamp::set_time_has_started_for_testing(core);

        init_module(owner);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            100000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000, // End time in the future
            5, // Set max quantity per wallet
            STAGE_PRIVATE_SALE // Set stage to presale
        );
        // Check sold out status when nothing is sold yet
        assert!(!has_sold_out(), 0);

        // Manually set current_sold to max_presale_size to simulate sold out
        let state = borrow_state_mut();
        // let config = borrow_launchpad_config();
        state.current_sold = 1000;

        // Check sold out status
        assert!(has_sold_out(), 0);
    }

    // Test successful whitelist purchase with referral code
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, userA = @0xAA
    )]
    fun test_purchase_by_public_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        userA: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);
        timestamp::update_global_time_for_test_secs(20000); // Set a fixed time within presale period

        let userA_addr = signer::address_of(userA);
        let metadata = setup_testing_token(owner, userA_addr, 20000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_to_whitelist(admin, userA_addr); // Add user to whitelist

        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 1, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 1, // End time in the future
            5,
            STAGE_GTD_WL // Set stage to presale
        );
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 1, // End time in the future
            5,
            STAGE_FCFS_WL // Set stage to presale
        );

        timestamp::update_global_time_for_test_secs(21000); // Set a fixed time within presale period

        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000, // End time in the future
            5,
            STAGE_PUBLIC // Set stage to presale
        );

        purchase(userA, metadata, 4, option::none());

        let config = borrow_launchpad_config();
        let payments = borrow_payments();
        let user_payments = table::borrow(&payments.payments, userA_addr);

        // assert!(vector::length(user_payments) == 1, 0);
        let payment = vector::borrow(user_payments, 0);
        assert!(payment.quantity == 4, 0);
        assert!(payment.amount == 4000000, 0);
        assert!(payment.buyer == userA_addr, 0);
        assert!(
            primary_fungible_store::balance(config.treasury_addr, metadata) == 4000000,
            0
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test successful whitelist purchase with referral code
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, userA = @0xAA, userB = @0xBB
    )]
    fun test_purchase_by_whitelist_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        userA: &signer,
        userB: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);
        timestamp::update_global_time_for_test_secs(20000); // Set a fixed time within presale period

        let userA_addr = signer::address_of(userA);
        let userB_addr = signer::address_of(userB);
        let metadata = setup_testing_token(owner, userA_addr, 20000000);
        let metadata_addr = object::object_address(&metadata);

        primary_fungible_store::transfer(
            userA,
            metadata,
            signer::address_of(userB),
            10000000
        );

        init_module(owner);
        add_to_whitelist(admin, userA_addr); // Add user to whitelist

        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds() - 16000, // Start time in the future
            timestamp::now_seconds() - 15000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000, // End time in the future
            5, // Set max quantity per wallet
            STAGE_GTD_WL // Set stage to whitelist
        );

        let code = string::utf8(b"ABCDE1");

        // referral::create_referral_code(userB, code, 5); // Create referral code with 5 uses and 100000000 price per item
        // User purchases 3 items with a code (here, code is none)
        purchase_by_whitelist(userA, metadata, 3, option::none());
        create_referral_code(userA, code); // Create referral code for user A

        purchase_by_whitelist(userB, metadata, 2, option::some(code));

        let config = borrow_launchpad_config();
        let payments = borrow_payments();
        let user_payments = table::borrow(&payments.payments, userA_addr);

        // assert!(vector::length(user_payments) == 1, 0);
        let payment = vector::borrow(user_payments, 0);
        assert!(payment.quantity == 3, 0);
        assert!(payment.amount == 3000000, 0);
        assert!(payment.buyer == userA_addr, 0);
        assert!(
            primary_fungible_store::balance(config.treasury_addr, metadata) == 5000000,
            0
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test whitelist purchase rejection in wrong stage
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = EWRONG_STAGE_NOT_WHITELIST, location = Self)]
    fun test_purchase_by_whitelist_in_invalid_stage(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);
        timestamp::update_global_time_for_test_secs(100); // Set time before presale starts
        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);
        init_module(owner);
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );
        purchase_by_whitelist(user, metadata, 2, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Create test fungible asset for purchases
    #[test_only]
    fun setup_testing_token(
        owner: &signer, user_addr: address, quantity: u64
    ): (object::Object<fungible_asset::Metadata>) {
        let (creator_ref, token_object) = fungible_asset::create_test_token(owner);
        let (mint_ref, _transfer_ref, _burn_ref) =
            init_testing_token_metadata(&creator_ref);

        primary_fungible_store::mint(&mint_ref, user_addr, quantity);
        // primary_fungible_store::mint(&mint_ref, userB_addr, 10000000);
        let metadata =
            object::convert<fungible_asset::TestToken, fungible_asset::Metadata>(
                token_object
            );

        (metadata)

    }

    // Initialize test token metadata with standard configuration
    #[test_only]
    fun init_testing_token_metadata(
        constructor_ref: &object::ConstructorRef
    ): (fungible_asset::MintRef, fungible_asset::TransferRef, fungible_asset::BurnRef) {
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::some(100000000), // max supply
            string::utf8(b"TEST COIN"),
            string::utf8(b"@T"),
            6,
            string::utf8(b"http://example.com/icon"),
            string::utf8(b"http://example.com")
        );
        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        (mint_ref, transfer_ref, burn_ref)
    }

    // Test adding and removing accepted coin types
    #[test(owner = @presale, admin = @admin_addr)]
    fun test_add_and_remove_accepted_coin_id(
        owner: &signer, admin: &signer
    ) acquires LaunchpadConfig {
        init_module(owner);

        // Test adding a new coin ID
        let new_coin_id = @0x333;
        add_accepted_coin_id(admin, new_coin_id);

        // Verify the coin ID was added
        let config = borrow_launchpad_config();
        assert!(vector::contains(&config.accepted_coin_ids, &new_coin_id), 0);

        // Test removing the coin ID
        remove_accepted_coin_id(admin, new_coin_id);

        // Verify the coin ID was removed
        let config = borrow_launchpad_config();
        assert!(!vector::contains(&config.accepted_coin_ids, &new_coin_id), 0);
    }

    // Test rejection of duplicate coin type additions
    #[test(owner = @presale, admin = @admin_addr)]
    #[expected_failure(abort_code = ECOIN_TYPE_ALREADY_ACCEPTED, location = Self)]
    fun test_add_duplicate_coin_id(owner: &signer, admin: &signer) acquires LaunchpadConfig {
        init_module(owner);

        // Add a coin ID
        let new_coin_id = @0x444;
        add_accepted_coin_id(admin, new_coin_id);

        // Try to add the same coin ID again - should fail with ECOIN_ALREADY_EXISTS
        add_accepted_coin_id(admin, new_coin_id);
    }

    // Test removal of non-existent coin type
    #[test(owner = @presale, admin = @admin_addr)]
    #[expected_failure(abort_code = EUNSUPPORTED_COIN_TYPE, location = Self)]
    fun test_remove_nonexistent_coin_id(owner: &signer, admin: &signer) acquires LaunchpadConfig {
        init_module(owner);

        // Try to remove a coin ID that doesn't exist - should fail with EINVALID_COIN_TYPE
        let non_existent_coin_id = @0x555;
        remove_accepted_coin_id(admin, non_existent_coin_id);
    }

    // Test purchase rejection when exceeding stage capacity
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = ESOLD_OUT, location = Self)]
    fun test_purchase_exceeds_max_size_should_fail(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, user);

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 500);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_to_whitelist(admin, user_addr); // Add user to whitelist
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            3, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5, // Set max quantity per wallet
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        // User tries to purchase 6 items, exceeding the max presale size of 5 - should fail
        purchase_by_private_sale(user, metadata, 4, option::none());

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test user purchase quantity tracking
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, userA = @0xAA, userB = @0xBB
    )]
    fun test_get_user_purchase_quantity(
        core: &signer,
        owner: &signer,
        admin: &signer,
        userA: &signer,
        userB: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, userA);

        // Set up initial test conditions
        let userA_addr = signer::address_of(userA);
        let userB_addr = signer::address_of(userB);

        let metadata = setup_testing_token(owner, userA_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            10, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time
            timestamp::now_seconds() + 2000, // End time
            5, // Set max quantity per wallet
            STAGE_PRIVATE_SALE // Set stage to presale
        );

        // Add userA to whitelist and make a purchase
        add_to_whitelist(admin, userA_addr);
        let purchase_quantity = 3;
        purchase_by_private_sale(
            userA,
            metadata,
            purchase_quantity,
            option::none()
        );

        // Test 1: Check that userA's purchase quantity is recorded correctly
        let userA_quantity = get_user_purchase_quantity(userA_addr);
        assert!(userA_quantity == purchase_quantity, 0);

        // Test 2: Check that userB (who hasn't purchased) returns 0
        let userB_quantity = get_user_purchase_quantity(userB_addr);
        assert!(userB_quantity == 0, 0);

        // Test 3: Check a non-existent user returns 0
        let nonexistent_addr = @0xDEAD;
        let nonexistent_quantity = get_user_purchase_quantity(nonexistent_addr);
        assert!(nonexistent_quantity == 0, 0);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // Test successful presale stage configuration update
    #[test(owner = @presale, admin = @admin_addr)]
    fun test_update_presale_stage_success(owner: &signer, admin: &signer) acquires LaunchpadConfig {
        init_module(owner);

        // Set up test parameters
        let max_size = 500;
        let price = 2000000;
        let start_time = 1000;
        let end_time = 2000;
        let max_quantity = 3;
        let stage_index = STAGE_PRIVATE_SALE;

        // Update stage
        update_presale_stage(
            admin,
            max_size,
            price,
            start_time,
            end_time,
            max_quantity,
            stage_index
        );

        // Verify stage was updated correctly
        let config = borrow_launchpad_config();
        assert!(config.stage == stage_index, 0);

        let stage = get_stage_by_index(config, stage_index);
        assert!(stage.presale_max_size == max_size, 0);
        assert!(stage.presale_price == price, 0);
        assert!(stage.presale_start_time == start_time, 0);
        assert!(stage.presale_end_time == end_time, 0);
        assert!(stage.max_quantity_per_wallet == max_quantity, 0);
    }

    // Test updating existing presale stage configuration
    #[test(owner = @presale, admin = @admin_addr)]
    fun test_update_existing_presale_stage(
        owner: &signer, admin: &signer
    ) acquires LaunchpadConfig {
        init_module(owner);

        // Set initial stage values
        let initial_max_size = 500;
        let initial_price = 2000000;
        let initial_start_time = 1000;
        let initial_end_time = 2000;
        let initial_max_quantity = 3;
        let stage_index = STAGE_PRIVATE_SALE;

        update_presale_stage(
            admin,
            initial_max_size,
            initial_price,
            initial_start_time,
            initial_end_time,
            initial_max_quantity,
            stage_index
        );

        // Update with new values
        let new_max_size = 800;
        let new_price = 3000000;
        let new_start_time = 3000;
        let new_end_time = 5000;
        let new_max_quantity = 5;

        update_presale_stage(
            admin,
            new_max_size,
            new_price,
            new_start_time,
            new_end_time,
            new_max_quantity,
            stage_index
        );

        // Verify stage was updated with new values
        let config = borrow_launchpad_config();
        let stage = get_stage_by_index(config, stage_index);

        assert!(stage.presale_max_size == new_max_size, 0);
        assert!(stage.presale_price == new_price, 0);
        assert!(stage.presale_start_time == new_start_time, 0);
        assert!(stage.presale_end_time == new_end_time, 0);
        assert!(stage.max_quantity_per_wallet == new_max_quantity, 0);
    }

    // Test stage update rejection by unauthorized users
    #[test(owner = @presale, normal_user = @0x123)]
    #[expected_failure(abort_code = ENOT_AUTHORIZED, location = Self)]
    fun test_update_presale_stage_without_admin_role(
        owner: &signer, normal_user: &signer
    ) acquires LaunchpadConfig {
        init_module(owner);

        // Non-admin user tries to update stage - should fail
        update_presale_stage(
            normal_user,
            500,
            2000000,
            1000,
            2000,
            3,
            STAGE_PRIVATE_SALE
        );
    }

    // Test stage update rejection with invalid time range
    #[test(owner = @presale, admin = @admin_addr)]
    #[expected_failure(abort_code = EINVALID_TIME_RANGE, location = Self)]
    fun test_update_presale_stage_with_invalid_time_range(
        owner: &signer, admin: &signer
    ) acquires LaunchpadConfig {
        init_module(owner);

        // Try to update with start time > end time - should fail
        update_presale_stage(
            admin,
            500,
            2000000,
            2000, // Start time
            1000, // End time (earlier than start time)
            3,
            STAGE_PRIVATE_SALE
        );
    }

    // Test referral code creation rejection for insufficient purchases
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, userA = @0xAA, userB = @0xBB
    )]
    #[expected_failure(abort_code = EUSER_NOT_QUALIFIED_FOR_REFERRAL, location = Self)]
    fun test_create_referral_code_after_purchase_2_nfts(
        core: &signer,
        owner: &signer,
        admin: &signer,
        userA: &signer,
        userB: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, userA);
        let userA_addr = signer::address_of(userA);

        let metadata = setup_testing_token(owner, userA_addr, 20000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_accepted_coin_id(admin, metadata_addr);
        update_presale_stage(
            admin,
            5, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000, // End time in the future
            5,
            STAGE_PRIVATE_SALE // Set stage to presale
        );
        add_to_whitelist(admin, userA_addr); // Add user A to whitelist
        purchase_by_private_sale(userA, metadata, 2, option::none());
        let code = string::utf8(b"ABCDE1234");

        create_referral_code(userA, code);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
