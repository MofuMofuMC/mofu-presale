module presale::whitelist {
    // use aptos_framework::timestamp;
    use std::signer;
    use aptos_framework::event::{Self};
    use aptos_std::table::{Self, Table};

    friend presale::presale;

    #[test_only]
    use std::error;

    #[test_only]
    use aptos_framework::timestamp;

    // === Events ===

    // Event emitted when a user is added to the whitelist
    #[event]
    struct WhitelistAddedEvent has drop, store {
        user_addr: address
    }

    // Event emitted when a user is removed from the whitelist
    #[event]
    struct WhitelistRemovedEvent has drop, store {
        user_addr: address
    }

    // === Error Codes ===

    // User is not in the whitelist
    const EWHITELIST_NOT_EXISTS: u64 = 1;
    // User is already in the whitelist
    const EWHITELIST_ALREADY_EXISTS: u64 = 2;
    // Whitelist configuration does not exist
    const EWHITELIST_CONFIG_NOT_EXISTS: u64 = 3;
    // User does not have enough quantity to deduct
    const EINSUFFICIENT_QUANTITY: u64 = 4;
    // Amount must be greater than zero
    const EAMOUNT_MUST_BE_GREATER_THAN_ZERO: u64 = 5;

    const ENOT_IN_WHITELIST_PRESALE_PERIOD: u64 = 6;

    // === Structs ===

    // Configuration for whitelist management
    // Contains whitelisted addresses with their allowed quantities and minting time period
    struct WhitelistConfig has key {
        // Mapping of whitelisted addresses to their allowed quantities
        whitelisted_address: Table<address, u64>
        // // Start time for whitelist minting period
        // whitelist_presale_start_time: u64,
        // // End time for whitelist minting period
        // whitelist_presale_end_time: u64
    }

    // === Public Functions ===

    // Initialize the whitelist configuration
    // This should be called once during module deployment
    public(friend) fun init_whitelist_config(admin: &signer) {
        let config = WhitelistConfig {
            whitelisted_address: table::new<address, u64>()
            // whitelist_presale_start_time: 0,
            // whitelist_presale_end_time: 0
        };
        move_to(admin, config);
    }

    // === Public-Friend Functions ===

    // Remove a user from the whitelist
    // Can only be called by friend modules (presale module)
    public(friend) fun remove_from_whitelist(user_addr: address) acquires WhitelistConfig {
        assert_whitelist_config_exists();

        let config = borrow_whitelist_config_mut();
        let is_whitelisted = table::contains(&config.whitelisted_address, user_addr);
        assert!(is_whitelisted == true, EWHITELIST_NOT_EXISTS);

        table::remove(&mut config.whitelisted_address, user_addr);
        event::emit(WhitelistRemovedEvent { user_addr });
    }

    // Update the whitelist minting time period
    // Sets the start and end times for when whitelisted users can mint
    // public(friend) fun update_whitelist_presale_times(
    //     whitelist_presale_start_time: u64, whitelist_presale_end_time: u64
    // ) acquires WhitelistConfig {
    //     assert_whitelist_config_exists();

    //     let config = borrow_whitelist_config_mut();
    //     config.whitelist_presale_start_time = whitelist_presale_start_time;
    //     config.whitelist_presale_end_time = whitelist_presale_end_time;
    // }

    // Add a user to the whitelist with specified quantity
    // Can only be called by friend modules (presale module)
    public(friend) fun add_to_whitelist(user_addr: address, amount: u64) acquires WhitelistConfig {
        assert!(amount > 0, EAMOUNT_MUST_BE_GREATER_THAN_ZERO);
        assert_whitelist_config_exists();
        add_whitelist_internal(user_addr, amount);
    }

    // Decrease the whitelist allocation for a user by the given mint (sale) amount.
    // Called when a user makes a whitelist mint/purchase.
    public(friend) fun decrease_whitelist_mint_amount(
        sender: &signer, quantity: u64
    ) acquires WhitelistConfig {
        assert_whitelist_config_exists();

        let config = borrow_whitelist_config_mut();
        let user_addr = signer::address_of(sender);
        let is_whitelisted = table::contains(&config.whitelisted_address, user_addr);
        assert!(is_whitelisted == true, EWHITELIST_NOT_EXISTS);

        let current_quantity =
            table::borrow_mut(&mut config.whitelisted_address, user_addr);
        assert!(*current_quantity >= quantity, EINSUFFICIENT_QUANTITY);

        *current_quantity = *current_quantity - quantity;
    }

    // public(friend) fun assert_within_whitelist_presale_period() acquires WhitelistConfig {
    //     assert_whitelist_config_exists();
    //     let config = borrow_whitelist_config();
    //     let now = timestamp::now_seconds();

    //     // Check if current time is within whitelist minting period
    //     assert!(
    //         now >= config.whitelist_presale_start_time
    //             && now <= config.whitelist_presale_end_time,
    //         ENOT_IN_WHITELIST_PRESALE_PERIOD
    //     );
    // }

    // === Functions ===

    // Internal function to add a user to the whitelist
    // Ensures no duplicate entries and emits appropriate events
    fun add_whitelist_internal(user_addr: address, amount: u64) acquires WhitelistConfig {
        let config = borrow_whitelist_config_mut();
        let is_whitelisted = table::contains(&config.whitelisted_address, user_addr);

        assert!(is_whitelisted == false, EWHITELIST_ALREADY_EXISTS);

        table::add(&mut config.whitelisted_address, user_addr, amount);
        event::emit(WhitelistAddedEvent { user_addr });
    }

    // === Public-View Functions ===

    // Check if a user is in the whitelist
    #[view]
    public fun has_whitelist(user_addr: address): bool acquires WhitelistConfig {
        let config = borrow_whitelist_config();
        table::contains(&config.whitelisted_address, user_addr)
    }

    // Check if whitelist configuration exists for a given module address
    #[view]
    public fun whitelist_config_exists(module_address: address): bool {
        exists<WhitelistConfig>(module_address)
    }

    // Get the eligible minting quantity for a user during whitelist period (0 if not whitelisted or outside time period)
    #[view]
    public fun is_user_eligible_for_whitelist_mint(user_addr: address): u64 acquires WhitelistConfig {
        // Return 0 if whitelist config doesn't exist
        if (!whitelist_config_exists(@presale)) {
            return 0
        };

        let config = borrow_whitelist_config();
        // let now = timestamp::now_seconds();

        // Check if user is whitelisted
        let is_whitelisted = table::contains(&config.whitelisted_address, user_addr);
        if (is_whitelisted) {
            let quantity = table::borrow(&config.whitelisted_address, user_addr);
            return *quantity
        };

        0
    }

    // === Inline Functions ===

    // Get immutable reference to whitelist configuration
    inline fun borrow_whitelist_config(): &WhitelistConfig acquires WhitelistConfig {
        borrow_global<WhitelistConfig>(@presale)
    }

    // Get mutable reference to whitelist configuration
    inline fun borrow_whitelist_config_mut(): &mut WhitelistConfig acquires WhitelistConfig {
        borrow_global_mut<WhitelistConfig>(@presale)
    }

    // Assert that whitelist configuration exists
    // Aborts with EWHITELIST_CONFIG_NOT_EXISTS if it doesn't exist
    inline fun assert_whitelist_config_exists() acquires WhitelistConfig {
        assert!(whitelist_config_exists(@presale), EWHITELIST_CONFIG_NOT_EXISTS);
    }

    // === Test Cases ===

    #[test(sender = @presale, user = @0xA)]
    fun test_init_whitelist_config_ok(sender: &signer, user: &signer) acquires WhitelistConfig {
        init_whitelist_config(sender);
        assert!(whitelist_config_exists(@presale), error::permission_denied(1));

        let user_addr = signer::address_of(user);
        add_to_whitelist(user_addr, 5);
        assert!(has_whitelist(signer::address_of(user)), 0);

        remove_from_whitelist(user_addr);
        assert!(!has_whitelist(signer::address_of(user)), 0);
    }

    #[test(sender = @presale, user = @0xA)]
    #[expected_failure(
        abort_code = EWHITELIST_ALREADY_EXISTS, location = presale::whitelist
    )]
    fun test_add_duplicate_whitelist(sender: &signer, user: &signer) acquires WhitelistConfig {
        init_whitelist_config(sender);
        add_whitelist_internal(signer::address_of(user), 5);
        assert!(has_whitelist(signer::address_of(user)), 0);

        add_whitelist_internal(signer::address_of(user), 5);
    }

    #[test(sender = @presale, user = @0xA)]
    #[expected_failure(abort_code = EWHITELIST_NOT_EXISTS, location = presale::whitelist)]
    fun test_remove_nonexistent_whitelist(
        sender: &signer, user: &signer
    ) acquires WhitelistConfig {
        init_whitelist_config(sender);
        let user_addr = signer::address_of(user);
        remove_from_whitelist(user_addr);
    }

    #[test(framework = @0x1, sender = @presale, user = @0xA)]
    fun test_is_user_eligible_for_whitelist_mint_ok(
        framework: signer, sender: &signer, user: &signer
    ) acquires WhitelistConfig {
        timestamp::set_time_has_started_for_testing(&framework);
        timestamp::update_global_time_for_test_secs(10000);
        init_whitelist_config(sender);

        let user_addr = signer::address_of(user);
        add_whitelist_internal(user_addr, 5);
        // let now = timestamp::now_seconds();
        // update_whitelist_presale_times(now - 100, now + 100);

        let quantity = is_user_eligible_for_whitelist_mint(user_addr);
        assert!(quantity == 5, 0);

        remove_from_whitelist(user_addr);
        let quantity_after_removal = is_user_eligible_for_whitelist_mint(user_addr);
        assert!(quantity_after_removal == 0, 0);
    }

    // #[test(sender = @presale)]
    // public fun test_update_whitelist_presale_time_ok(sender: &signer) acquires WhitelistConfig {
    //     init_whitelist_config(sender);
    //     let start_time = 1000;
    //     let end_time = 2000;

    //     update_whitelist_presale_times(start_time, end_time);

    //     let config = borrow_whitelist_config();
    //     assert!(
    //         config.whitelist_presale_start_time == start_time,
    //         0
    //     );
    //     assert!(config.whitelist_presale_end_time == end_time, 0);
    // }

    // #[test(sender = @presale)]
    // public fun test_update_whitelist_presale_time_by_invalid_times(
    //     sender: &signer
    // ) acquires WhitelistConfig {
    //     init_whitelist_config(sender);
    //     let start_time = 3000;
    //     let end_time = 2000;

    //     update_whitelist_presale_times(start_time, end_time);

    //     let config = borrow_whitelist_config();
    //     assert!(
    //         config.whitelist_presale_start_time == start_time,
    //         0
    //     );
    //     assert!(config.whitelist_presale_end_time == end_time, 0);
    // }

    #[test(sender = @presale, user = @0xA)]
    fun test_decrease_whitelist_mint_amount_ok(
        sender: &signer, user: &signer
    ) acquires WhitelistConfig {
        init_whitelist_config(sender);
        let user_addr = signer::address_of(user);

        // Add user to whitelist with default quantity 5
        add_whitelist_internal(user_addr, 5);

        let config = borrow_whitelist_config();
        let initial_quantity = table::borrow(&config.whitelisted_address, user_addr);
        assert!(*initial_quantity == 5, 0);

        // Deduct 2 from quantity
        decrease_whitelist_mint_amount(user, 2);

        let config = borrow_whitelist_config();
        let remaining_quantity = table::borrow(&config.whitelisted_address, user_addr);
        assert!(*remaining_quantity == 3, 0);

        // Deduct remaining 3
        decrease_whitelist_mint_amount(user, 3);

        let config = borrow_whitelist_config();
        let final_quantity = table::borrow(&config.whitelisted_address, user_addr);
        assert!(*final_quantity == 0, 0);
    }

    #[test(sender = @presale, user = @0xA)]
    #[expected_failure(abort_code = EINSUFFICIENT_QUANTITY, location = presale::whitelist)]
    fun test_decrease_whitelist_mint_amount_insufficient(
        sender: &signer, user: &signer
    ) acquires WhitelistConfig {
        init_whitelist_config(sender);
        let user_addr = signer::address_of(user);

        // Add user to whitelist with default quantity 5
        add_whitelist_internal(user_addr, 5);

        decrease_whitelist_mint_amount(user, 6);
    }

    #[test(sender = @presale, user = @0xA)]
    #[expected_failure(abort_code = EWHITELIST_NOT_EXISTS, location = presale::whitelist)]
    fun test_decrease_whitelist_mint_amount_not_whitelisted(
        sender: &signer, user: &signer
    ) acquires WhitelistConfig {
        init_whitelist_config(sender);
        decrease_whitelist_mint_amount(user, 1);
    }

    // #[test(framework = @0x1, sender = @presale)]
    // public fun test_assert_within_whitelist_presale_period_ok(
    //     framework: signer, sender: &signer
    // ) acquires WhitelistConfig {
    //     timestamp::set_time_has_started_for_testing(&framework);
    //     timestamp::update_global_time_for_test_secs(10000);
    //     init_whitelist_config(sender);

    //     let now = timestamp::now_seconds();
    //     update_whitelist_presale_times(now - 100, now + 100);

    //     // Should not abort
    //     assert_within_whitelist_presale_period();
    // }

    // #[test(framework = @0x1, sender = @presale)]
    // #[
    //     expected_failure(
    //         abort_code = ENOT_IN_WHITELIST_PRESALE_PERIOD, location = presale::whitelist
    //     )
    // ]
    // public fun test_assert_within_whitelist_presale_period_fail(
    //     framework: signer, sender: &signer
    // ) acquires WhitelistConfig {
    //     timestamp::set_time_has_started_for_testing(&framework);
    //     timestamp::update_global_time_for_test_secs(10000);
    //     init_whitelist_config(sender);

    //     let now = timestamp::now_seconds();
    //     update_whitelist_presale_times(now + 100, now + 200);

    //     // Should abort
    //     assert_within_whitelist_presale_period();
    // }
}
