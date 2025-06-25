module presale::presale {
    use aptos_framework::timestamp;
    use aptos_framework::aptos_account::{Self};
    use std::signer;
    use std::vector;
    use std::option::{Self};
    use std::string::{Self, String};
    use aptos_framework::type_info::{Self};
    use aptos_framework::event::{Self};
    use aptos_std::table::{Self, Table};
    use presale::whitelist::{Self};
    use presale::referral::{Self};
    use aptos_framework::randomness::{Self};
    use aptos_framework::object::{Self};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::primary_fungible_store;

    #[test_only]
    use aptos_framework::aptos_coin::{AptosCoin};

    #[test_only]
    use aptos_framework::coin;

    #[test_only]
    use aptos_framework::aptos_coin::{Self};

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    use std::error;

    // === Constants ===
    const STAGE_NONE: u64 = 0;
    const STAGE_WHITELIST: u64 = 1;
    const STAGE_PRESALE: u64 = 2;
    const STAGE_PUBLIC: u64 = 3;

    // === Structs ===
    struct LaunchpadConfig has key {
        treasury_addr: address,
        admin: address,
        accepted_coin_id: address,
        stage: u64,
        presale_configs: vector<PresaleStage>
    }

    struct PresaleStage has store {
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64
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
    const ESOLD_OUT: u64 = 1;
    const ENOT_AUTHORIZED: u64 = 2;
    const EINVALID_COIN_TYPE: u64 = 3;
    const EINVALID_PAYMENT: u64 = 4;
    const EINVALID_QUANTITY: u64 = 5;
    const ENOT_IN_PRESALE_TIME: u64 = 6;
    const ESTART_TIME_AFTER_END_TIME: u64 = 7;
    const ESTAGE_IS_NOT_PRESALE: u64 = 8; // Stage is not presale
    const ESTAGE_IS_NOT_WHITELIST: u64 = 9; // Stage is not whitelist
    const EINVALID_STAGE: u64 = 10; // Stage must be between 0 and 3
    const EHAS_ALREADY_PURCHASED: u64 = 11; // User has already purchased
    const EINVALID_CODE_LENGTH: u64 = 12;
    const ENOT_QUALIFIED_FOR_REFERRAL: u64 = 13; // User is not qualified for referral
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

    // === Initialization ===
    fun init_module(admin: &signer) {
        // let seed_vec = bcs::to_bytes(&timestamp::now_seconds());
        // let (resource_signer, resource_signer_cap) = account::create_resource_account(admin, seed_vec);
        let launchpad_config = LaunchpadConfig {
            treasury_addr: @treasury_addr,
            accepted_coin_id: ACCEPTED_COIN_METADATA_ID,
            admin: @admin_addr,
            stage: STAGE_WHITELIST,
            presale_configs: vector::empty<PresaleStage>()
        };
        let presale_config = PresaleStage {
            presale_max_size: DEFAULT_MAX_PRESALE_SIZE,
            presale_price: DEFAULT_SALE_PRICE,
            presale_start_time: 0,
            presale_end_time: 0
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
        referral::init_referral_registry(admin);
    }

    // === Public-Entry Functions ===
    public entry fun update_public_sale_stage(
        admin: &signer,
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64
    ) acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let launchpad_config = borrow_launchpad_config_mut();

        assert!(is_admin(launchpad_config, admin_addr), ENOT_AUTHORIZED);
        assert!(presale_start_time < presale_end_time, ESTART_TIME_AFTER_END_TIME); // Start time must be before end time

        launchpad_config.stage = STAGE_PUBLIC; // Set stage to public sale
        reset_current_sold();
        add_or_update_stage(
            admin,
            presale_max_size,
            presale_price,
            presale_start_time,
            presale_end_time,
            STAGE_WHITELIST
        );
    }

    public entry fun update_private_presale_stage(
        admin: &signer,
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64
    ) acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let launchpad_config = borrow_launchpad_config_mut();

        assert!(is_admin(launchpad_config, admin_addr), ENOT_AUTHORIZED);
        assert!(presale_start_time < presale_end_time, ESTART_TIME_AFTER_END_TIME); // Start time must be before end time

        launchpad_config.stage = STAGE_PRESALE; // Set stage to presale
        reset_current_sold();
        add_or_update_stage(
            admin,
            presale_max_size,
            presale_price,
            presale_start_time,
            presale_end_time,
            STAGE_PRESALE
        );
    }

    public entry fun update_whitelist_sale_stage(
        admin: &signer,
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64
    ) acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let launchpad_config = borrow_launchpad_config_mut();
        assert!(is_admin(launchpad_config, admin_addr), ENOT_AUTHORIZED);
        assert!(presale_start_time < presale_end_time, ESTART_TIME_AFTER_END_TIME); // Start time must be before end time

        launchpad_config.stage = STAGE_WHITELIST; // Set stage to whitelist
        reset_current_sold();
        add_or_update_stage(
            admin,
            presale_max_size,
            presale_price,
            presale_start_time,
            presale_end_time,
            STAGE_WHITELIST
        );
        whitelist::update_whitelist_presale_times(presale_start_time, presale_end_time);
    }

    fun add_or_update_stage(
        admin: &signer,
        presale_max_size: u64,
        presale_price: u64,
        presale_start_time: u64,
        presale_end_time: u64,
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
                presale_end_time
            };
            vector::push_back(&mut launchpad_config.presale_configs, presale_stage);
        } else {
            let stage = vector::borrow_mut(&mut launchpad_config.presale_configs, stage);
            stage.presale_max_size = presale_max_size;
            stage.presale_price = presale_price;
            stage.presale_start_time = presale_start_time;
            stage.presale_end_time = presale_end_time;
        };
    }

    /// Sets the treasury address for the launchpad.
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

    /// Adds a user to the whitelist with a maximum quantity per purchase.
    public entry fun add_to_whitelist(admin: &signer, user_addr: address) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let config = borrow_launchpad_config_mut();
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        whitelist::add_to_whitelist(user_addr, MAX_QUANTITY_PER_PURCHASE);
    }

    /// Removes a user from the whitelist.
    public entry fun remove_from_whitelist(
        admin: &signer, user_addr: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let admin_addr = signer::address_of(admin);
        let config = borrow_launchpad_config_mut();
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        whitelist::remove_from_whitelist(user_addr);
    }

    /// Sets a new admin for the launchpad.
    public entry fun set_admin(admin: &signer, new_admin: address) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        config.admin = new_admin;
    }

    /// Sets the accepted coin type for the presale.
    public entry fun set_accepted_coin_id(
        admin: &signer, new_coin_id: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);
        config.accepted_coin_id = new_coin_id;
    }

    // entry fun purchase<CoinType>() {}

    /// Purchases items during the presale using a referral code.
    public entry fun purchase_by_code(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        quantity: u64,
        code: string::String
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        assert_launchpad_config_exists();
        assert_within_presale_period();
        assert_not_sold_out();
        assert_quantity_in_range(quantity, 2);
        assert_has_not_purchased(signer::address_of(sender));
        referral::assert_referral_code_available(code);

        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, STAGE_PRESALE);
        assert!(
            launchpad_config.stage == STAGE_PRESALE,
            ESTAGE_IS_NOT_WHITELIST
        );

        let launchpad_state = borrow_state();
        // Check if presale is sold out
        assert!(
            launchpad_state.current_sold + (quantity as u64)
                <= presale_stage.presale_max_size,
            ESOLD_OUT
        ); // Presale sold out

        let total_price =
            purchase_internal_with_asset(sender, metadata, quantity, option::some(code));

        referral::increase_current_invites(signer::address_of(sender), code, quantity);

        event::emit(
            PurchasedEvent {
                buyer: signer::address_of(sender),
                quantity,
                amount: total_price,
                timestamp: timestamp::now_seconds(),
                code: option::some(code)
            }
        );
    }

    public entry fun purchase_by_whitelist(
        sender: &signer, metadata: object::Object<fungible_asset::Metadata>, quantity: u64
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        assert_launchpad_config_exists();
        assert_within_presale_period();
        assert_not_sold_out();
        assert_quantity_in_range(quantity, MAX_QUANTITY_PER_PURCHASE);
        assert_has_not_purchased(signer::address_of(sender));

        let launchpad_config = borrow_launchpad_config();
        let presale_config = get_stage_by_index(launchpad_config, STAGE_WHITELIST);
        assert!(
            launchpad_config.stage == STAGE_WHITELIST,
            ESTAGE_IS_NOT_PRESALE
        );

        let launchpad_state = borrow_state();
        // Check if presale is sold out
        assert!(
            launchpad_state.current_sold + (quantity as u64)
                <= presale_config.presale_max_size,
            ESOLD_OUT
        ); // Presale sold out

        let total_price =
            purchase_internal_with_asset(sender, metadata, quantity, option::none());
        whitelist::decrease_whitelist_mint_amount(sender, quantity);

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

    public entry fun create_referral_code(
        sender: &signer, code: string::String
    ) acquires Payments {
        let buyer = signer::address_of(sender);
        // Check code length is valid (between 6 and 30 characters)
        let code_length = string::length(&code);
        assert!(
            code_length >= 6 && code_length <= 30,
            EINVALID_CODE_LENGTH
        );

        let payments = borrow_payments_mut();
        let user_payments =
            table::borrow_mut_with_default(
                &mut payments.payments, buyer, vector::empty<Payment>()
            );

        assert!(vector::length(user_payments) > 0, 0); // User has already purchased

        let user_payment = vector::borrow(user_payments, 0); // Ensure the user has no previous payments
        let quantity = user_payment.quantity;
        assert!(quantity > 2, ENOT_QUALIFIED_FOR_REFERRAL);

        let max_invites = {
            if (quantity <= 4) { 10 }
            else { 1000 }
        };
        referral::create_referral_code(sender, code, max_invites);
        // Return the generated code
    }

    // === Private Functions ===
    // fun pay_for_presale<CoinType>(
    //     buyer: &signer, total_price: u64, treasury_addr: address
    // ) {
    //     assert!(total_price > 0, EINVALID_PAYMENT);
    //     // Transfer payment to treasury using AptosCoin specifically
    //     aptos_account::transfer_coins<CoinType>(buyer, treasury_addr, total_price);
    // }

    fun pay_for_presale(
        sender: &signer,
        metadata: object::Object<fungible_asset::Metadata>,
        amount: u64,
        treasury_addr: address
    ) {
        // let amount = fungible_asset::amount(&asset);
        assert!(amount > 0, EINVALID_PAYMENT);
        // Transfer fungible asset to treasury

        aptos_account::transfer_fungible_assets(sender, metadata, treasury_addr, amount);
    }

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
            metadata_object_address == launchpad_config.accepted_coin_id,
            EINVALID_COIN_TYPE
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

    /// Sets the accepted fungible asset metadata address for the presale.
    public entry fun set_accepted_asset_metadata(
        admin: &signer, metadata_address: address
    ) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let config = borrow_launchpad_config_mut();
        let admin_addr = signer::address_of(admin);
        assert!(is_admin(config, admin_addr), ENOT_AUTHORIZED);

        // Convert address to string for storage
        config.accepted_coin_id = metadata_address
    }

    //  === Public-View Functions ===
    #[view]
    public fun get_num_of_presale_stages(): u64 acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        vector::length(&launchpad_config.presale_configs) as u64
    }

    #[view]
    public fun get_stage_period_by_index(stage: u64): (u64, u64) acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        let stage = get_stage_by_index(launchpad_config, stage);
        (stage.presale_start_time, stage.presale_end_time)
    }

    #[view]
    public fun is_in_presale_period(stage: u64): bool acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        if (stage < vector::length(&launchpad_config.presale_configs)) {
            return false
        };
        let stage = get_stage_by_index(launchpad_config, stage);
        is_within_presale_period(
            stage.presale_start_time,
            stage.presale_end_time
        )
    }

    #[view]
    public fun get_presale_state(): (u64, u64) acquires LaunchpadState {
        assert_launchpad_config_exists();
        let launchpad_state = borrow_state();
        (launchpad_state.total_sold, launchpad_state.current_sold)
    }

    #[view]
    public fun launchpad_config_exists(module_address: address): bool {
        exists<LaunchpadConfig>(module_address)
    }

    #[view]
    public fun has_purchased(buyer: address): bool acquires Payments {
        let payments = borrow_payments();
        table::contains(&payments.payments, buyer)
    }

    #[view]
    public fun has_sold_out(): bool acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let launchpad_state = borrow_state();
        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);
        is_sold_out(launchpad_state.current_sold, presale_stage.presale_max_size)
    }

    // === Inline Functions ===
    inline fun get_stage_by_index(
        launchpad_config: &LaunchpadConfig, index: u64
    ): &PresaleStage acquires LaunchpadConfig {
        assert!(
            index < vector::length(&launchpad_config.presale_configs), EINVALID_STAGE
        );
        vector::borrow(&launchpad_config.presale_configs, index)
    }

    inline fun borrow_launchpad_config(): &LaunchpadConfig acquires LaunchpadConfig {
        borrow_global<LaunchpadConfig>(@presale)
    }

    inline fun borrow_launchpad_config_mut(): &mut LaunchpadConfig acquires LaunchpadConfig {
        borrow_global_mut<LaunchpadConfig>(@presale)
    }

    inline fun borrow_state(): &LaunchpadState acquires LaunchpadState {
        borrow_global<LaunchpadState>(@presale)
    }

    inline fun borrow_state_mut(): &mut LaunchpadState acquires LaunchpadState {
        borrow_global_mut<LaunchpadState>(@presale)
    }

    inline fun borrow_payments(): &Payments acquires Payments {
        let payments = borrow_global<Payments>(@presale);
        payments
    }

    inline fun borrow_payments_mut(): &mut Payments acquires Payments {
        let payments = borrow_global_mut<Payments>(@presale);
        payments
    }

    inline fun is_admin(config: &LaunchpadConfig, addr: address): bool {
        if (config.admin == addr) { true }
        else { false }
    }

    inline fun assert_is_admin(addr: address) {
        let config = borrow_global<LaunchpadConfig>(@presale);
        assert!(is_admin(config, addr), ENOT_AUTHORIZED);
    }

    inline fun assert_launchpad_config_exists() acquires LaunchpadConfig {
        assert!(
            exists<LaunchpadConfig>(@presale),
            ENOT_AUTHORIZED
        ); // Presale config not found
    }

    inline fun assert_quantity_in_range(quantity: u64, max_quantity: u64) {
        assert!(
            quantity > 0 && quantity <= max_quantity,
            EINVALID_QUANTITY
        ); // Invalid quantity
    }

    inline fun assert_has_not_purchased(buyer: address) acquires Payments {
        let payments = borrow_payments();
        assert!(
            !table::contains(&payments.payments, buyer),
            EHAS_ALREADY_PURCHASED
        ); // User has already purchased
    }

    inline fun is_sold_out(current_sold: u64, max_presale_size: u64): bool {
        current_sold >= max_presale_size
    }

    inline fun is_within_presale_period(
        presale_start_time: u64, presale_end_time: u64
    ): bool {
        let now = timestamp::now_seconds();
        now >= presale_start_time && now <= presale_end_time
    }

    inline fun reset_current_sold() acquires LaunchpadState {
        let launchpad_state = borrow_state_mut();
        launchpad_state.current_sold = 0;
    }

    inline fun assert_within_presale_period() acquires LaunchpadConfig {
        assert_launchpad_config_exists();
        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);

        assert!(
            is_within_presale_period(
                presale_stage.presale_start_time,
                presale_stage.presale_end_time
            ),
            ENOT_IN_PRESALE_TIME
        ); // Not in presale time
    }

    inline fun assert_not_sold_out() acquires LaunchpadConfig, LaunchpadState {
        assert_launchpad_config_exists();
        let launchpad_state = borrow_state();
        let launchpad_config = borrow_launchpad_config();
        let presale_stage = get_stage_by_index(launchpad_config, launchpad_config.stage);

        assert!(
            !is_sold_out(launchpad_state.current_sold, presale_stage.presale_max_size),
            ESOLD_OUT
        ); // Presale is sold out
    }

    #[test_only]
    use std::debug;

    #[test_only]
    use aptos_std::crypto_algebra::enable_cryptography_algebra_natives;

    #[test_only]
    use aptos_framework::account::create_account_for_test;

    #[test_only]
    #[lint::allow_unsafe_randomness]
    public fun init_module_for_test(
        aptos_framework: &signer, deployer: &signer, user: &signer
    ): (coin::BurnCapability<AptosCoin>, coin::MintCapability<AptosCoin>) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);

        enable_cryptography_algebra_natives(aptos_framework);
        randomness::initialize_for_testing(aptos_framework);
        randomness::set_seed(
            x"0000000000000000000000000000000000000000000000000000000000000000"
        );

        // create a fake account (only for testing purposes)
        create_account_for_test(signer::address_of(deployer));
        create_account_for_test(signer::address_of(user));
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(1005); // Set a fixed time for testing

        (burn_cap, mint_cap)
    }

    // === Tests ===
    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, userA = @0xAA, userB = @0xBB
    )]
    fun test_presale_flow_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        userA: &signer,
        userB: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = init_module_for_test(core, owner, userA);

        let owner_addr = signer::address_of(owner);
        let userA_addr = signer::address_of(userA);
        let userB_addr = signer::address_of(userB);

        let metadata = setup_testing_token(owner, userA_addr, 20000000);
        let metadata_addr = object::object_address(&metadata);

        primary_fungible_store::transfer(userA, metadata, userB_addr, 10000000);
        init_module(owner);
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            5, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        add_to_whitelist(admin, userA_addr); // Add user A to whitelist

        assert!(
            whitelist::is_user_eligible_for_whitelist_mint(userA_addr) == 5,
            error::permission_denied(1)
        );
        // User purchases 3 items
        purchase_by_whitelist(userA, metadata, 3);

        let launchpad_state = borrow_state();
        assert!(launchpad_state.total_sold == 3, error::permission_denied(1));
        // create_referral_code(userA); // User A creates a referral code
        let code = string::utf8(b"ABCDE1234");
        referral::create_referral_code(userA, code, 10);

        timestamp::update_global_time_for_test_secs(10005); // Set a fixed time for testing

        update_private_presale_stage(
            admin,
            5, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        purchase_by_code(userB, metadata, 2, code); // User B purchases using referral code
        let launchpad_state = borrow_state();
        assert!(launchpad_state.total_sold == 5, error::permission_denied(1));
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    fun test_purchase_by_whitelist_ok(
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
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            10, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        add_to_whitelist(admin, user_addr); // Add user to whitelist

        let owner_addr = signer::address_of(owner);
        assert!(launchpad_config_exists(owner_addr), error::not_found(1)); // Presale config not found
        assert!(
            whitelist::is_user_eligible_for_whitelist_mint(user_addr) == 5,
            error::permission_denied(1)
        );

        // User purchases 3 items
        purchase_by_whitelist(user, metadata, 3);

        let config = borrow_launchpad_config();
        let payments = borrow_payments();
        let user_payments = table::borrow(&payments.payments, user_addr);

        assert!(vector::length(user_payments) == 1, error::permission_denied(1));

        let payment = vector::borrow(user_payments, 0);
        assert!(payment.quantity == 3, error::permission_denied(1));
        assert!(payment.amount == 3000000, error::permission_denied(1)); // 3 * 100000000
        assert!(payment.buyer == user_addr, error::permission_denied(1));

        // check the treasury balance
        assert!(
            primary_fungible_store::balance(config.treasury_addr, metadata) == 3000000,
            2
        );
        assert!(
            whitelist::is_user_eligible_for_whitelist_mint(user_addr) == 2,
            error::permission_denied(1)
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_purchase_by_whitelist_over_max_quantity(
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
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            100000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        // Try to purchase 6 items (over MAX_QUANTITY_PER_PURCHASE = 5) - should fail
        purchase_by_whitelist(user, metadata, 6);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = EHAS_ALREADY_PURCHASED, location = Self)]
    // EINVALID_QUANTITY
    fun test_purchase_by_whitelist_two_times(
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
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        purchase_by_whitelist(user, metadata, 4);
        purchase_by_whitelist(user, metadata, 1);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = 5, location = Self)]
    // EINVALID_QUANTITY
    fun test_purchase_by_zero_quantity(
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
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        // Try to purchase 0 items - should fail
        purchase_by_whitelist(user, metadata, 0);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAB
    )]
    #[expected_failure(abort_code = 3, location = Self)]
    // EINVALID_COIN_TYPE
    fun test_purchase_wrong_coin_type(
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
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 2000 // End time in the future
        );

        // Try to purchase with AptosCoin when USDT is expected - should fail
        purchase_by_whitelist(user, metadata, 3);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

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
        assert!(config.treasury_addr == new_treasury_addr, error::permission_denied(1));

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(owner = @presale, admin = @admin_addr)]
    fun test_set_admin_ok(owner: &signer, admin: &signer) acquires LaunchpadConfig {
        init_module(owner);
        let new_admin = @0xA;
        set_admin(admin, new_admin);
        let config = borrow_launchpad_config();
        assert!(config.admin == new_admin, error::permission_denied(1));
    }

    #[test(owner = @presale, admin = @admin_addr)]
    fun test_set_accepted_coin_id_ok(owner: &signer, admin: &signer) acquires LaunchpadConfig {
        init_module(owner);
        // let owner_addr = signer::address_of(owner);
        // assert!(launchpad_config_exists(owner_addr), error::not_found(1)); // Presale config not found

        let new_coin_id = @0x02f;
        // Normal user tries to set accepted coin type - should fail
        set_accepted_coin_id(admin, new_coin_id);

        let config = borrow_launchpad_config();
        assert!(config.accepted_coin_id == new_coin_id, error::permission_denied(1));
    }

    #[test(owner = @presale)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_old_admin_cannot_set_admin_after_transfer(owner: &signer) acquires LaunchpadConfig {
        init_module(owner);
        let owner_addr = signer::address_of(owner);
        assert!(launchpad_config_exists(owner_addr), error::not_found(1)); // Presale config not found

        // Set new admin
        let new_admin = @0xA;
        set_admin(owner, new_admin);

        // Verify new admin is set
        let config = borrow_launchpad_config();
        assert!(config.admin == new_admin, error::permission_denied(1));

        // Old admin tries to set another admin - should fail
        let another_admin = @0xB;
        set_admin(owner, another_admin); // This should abort with ENOT_AUTHORIZED
    }

    // #[test(owner = @presale, normal_user = @0x123)]
    // #[expected_failure(abort_code = 2, location = Self)]
    // fun test_normal_user_cannot_set_max_presale_size(
    //     owner: &signer, normal_user: &signer
    // ) acquires LaunchpadConfig {
    //     init_module(owner);

    //     // Normal user tries to set max presale size - should fail
    //     let new_max_presale_size = 2000;
    //     set_max_presale_size(normal_user, new_max_presale_size);
    // }

    // #[test(owner = @presale, normal_user = @0x123)]
    // #[expected_failure(abort_code = 2, location = Self)]
    // fun test_normal_user_cannot_set_sale_price(
    //     owner: &signer, normal_user: &signer
    // ) acquires LaunchpadConfig {
    //     init_module(owner);

    //     // Normal user tries to set sale price - should fail
    //     let new_sale_price = 300;
    //     set_sale_price(normal_user, new_sale_price);
    // }

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
        assert!(launchpad_config_exists(owner_addr), error::not_found(1));

        // Normal user tries to set treasury - should fail
        set_treasury(normal_user, treasury_addr);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(owner = @presale)]
    #[expected_failure(abort_code = ENOT_AUTHORIZED, location = Self)]
    // error::not_found(1)
    fun test_set_admin_without_init(owner: &signer) acquires LaunchpadConfig {
        // Don't call init_module - try to set admin without initialization
        let new_admin = @0xA;
        set_admin(owner, new_admin);
    }

    #[test(core = @0x1, owner = @presale, treasury = @0x456)]
    #[expected_failure(abort_code = ENOT_AUTHORIZED, location = Self)]
    // error::not_found(1)
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

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = ENOT_IN_PRESALE_TIME, location = Self)]
    fun test_purchase_by_whitelist_outside_presale_time(
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

        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000 // End time in the future
        );
        timestamp::update_global_time_for_test_secs(16000); // Set time before presale starts

        // Try to purchase before presale starts (current time: 5000, start: 10000) - should fail
        purchase_by_whitelist(user, metadata, 3);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = 1, location = presale::whitelist)]
    fun test_purchase_by_whitelist_without_whitelist(
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
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000 // End time in the future
        );
        // Try to purchase without being whitelisted - should fail
        purchase_by_whitelist(user, metadata, 3);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(core = @0x1, owner = @presale, admin = @admin_addr)]
    fun test_has_sold_out_ok(
        core: &signer, owner: &signer, admin: &signer
    ) acquires LaunchpadConfig, LaunchpadState {
        timestamp::set_time_has_started_for_testing(core);

        init_module(owner);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            100000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000 // End time in the future
        );
        // Check sold out status when nothing is sold yet
        assert!(!has_sold_out(), error::permission_denied(1));

        // Manually set current_sold to max_presale_size to simulate sold out
        let state = borrow_state_mut();
        // let config = borrow_launchpad_config();
        state.current_sold = 1000;

        // Check sold out status
        assert!(has_sold_out(), error::permission_denied(1));
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    fun test_purchase_by_code_ok(
        core: &signer,
        owner: &signer,
        admin: &signer,
        user: &signer
    ) acquires LaunchpadConfig, LaunchpadState, Payments {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(core);
        timestamp::set_time_has_started_for_testing(core);
        timestamp::update_global_time_for_test_secs(20000); // Set a fixed time within presale period

        let user_addr = signer::address_of(user);
        let metadata = setup_testing_token(owner, user_addr, 10000000);
        let metadata_addr = object::object_address(&metadata);

        init_module(owner);
        add_to_whitelist(admin, user_addr); // Add user to whitelist

        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds() - 16000, // Start time in the future
            timestamp::now_seconds() - 15000 // End time in the future
        );

        update_private_presale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000 // End time in the future
        );

        let code = string::utf8(b"ABCDE1");

        referral::create_referral_code(user, code, 5); // Create referral code with 5 uses and 100000000 price per item
        // User purchases 3 items with a code (here, code is none)
        purchase_by_code(user, metadata, 2, code);

        let config = borrow_launchpad_config();
        let payments = borrow_payments();
        let user_payments = table::borrow(&payments.payments, user_addr);

        assert!(vector::length(user_payments) == 1, error::permission_denied(1));
        let payment = vector::borrow(user_payments, 0);
        assert!(payment.quantity == 2, error::permission_denied(1));
        assert!(payment.amount == 2000000, error::permission_denied(1));
        assert!(payment.buyer == user_addr, error::permission_denied(1));
        assert!(
            primary_fungible_store::balance(config.treasury_addr, metadata) == 2000000,
            2
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        core = @0x1, owner = @presale, admin = @admin_addr, user = @0xAA
    )]
    #[expected_failure(abort_code = EINVALID_STAGE, location = Self)]
    fun test_purchase_by_code_in_invalid_stage(
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
        set_accepted_coin_id(admin, metadata_addr);
        update_whitelist_sale_stage(
            admin,
            1000, // Set max presale size
            1000000, // Set sale price
            timestamp::now_seconds(), // Start time in the future
            timestamp::now_seconds() + 15000 // End time in the future
        );
        let code = string::utf8(b"ABCDE1");
        referral::create_referral_code(user, code, 5); // Create referral code with 5 uses and 100000000 price per item
        // Try to purchase before presale starts (current time: 5000, start: 10000) - should fail
        purchase_by_code(user, metadata, 2, code);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

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
}
