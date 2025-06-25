module presale::referral {
    use std::signer;
    use std::option;
    use aptos_framework::event::{Self};
    use aptos_std::table::{Self, Table};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_framework::aptos_account;
    use aptos_framework::timestamp;
    use aptos_framework::object::{
        Self,
        ConstructorRef,
        DeleteRef,
        ExtendRef,
        Object,
        ObjectCore,
        TransferRef
    };
    use std::string;

    friend presale::presale;

    // === Structs ===
    struct ReferralRegistry has key {
        codes: Table<ReferralCodeKey, ReferralCode>,
        user_to_code: SmartTable<address, string::String>
    }

    struct ReferralCode has store {
        code: string::String,
        creator: address,
        max_invites: u64,
        current_invites: u64,
        current_sales: u64
    }

    struct ReferralCodeKey has copy, store, drop {
        code: string::String
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Referral has key {
        code: string::String,
        creator: address,
        max_invites: u64,
        delete_ref: DeleteRef,
        extend_ref: ExtendRef
    }

    // === Error Codes ===
    const ECODE_EXISTS: u64 = 0x1;
    const ECODE_NOT_EXISTS: u64 = 0x2;
    const EREGISTRY_NOT_EXISTS: u64 = 0x3;
    const EMAX_INVITES_REACHED: u64 = 0x4;
    const ECODE_IS_NOT_AVAILABLE: u64 = 0x5;
    const ENO_CODE: u64 = 0x6;

    // === Events ===
    #[event]
    struct ReferralCodeCreated has store, drop {
        code: string::String,
        creator: address,
        max_invites: u64,
        timestamp: u64
    }

    // #[event]
    // struct ReferralRoyaltyPaid has store, drop {
    //     code: string::String,
    //     referrer: address,
    //     invitee: address,
    //     royalty_amount: u64,
    //     timestamp: u64
    // }

    #[event]
    struct ReferralRoyaltyMarked has store, drop {
        code: string::String,
        referrer: address,
        invitee: address,
        amount: u64,
        timestamp: u64
    }

    // === Public-Friend Functions ===

    public(friend) fun init_referral_registry(admin: &signer) {
        let registry = ReferralRegistry {
            codes: table::new<ReferralCodeKey, ReferralCode>(),
            user_to_code: smart_table::new<address, string::String>()
        };
        move_to(admin, registry);
    }

    public(friend) fun create_referral_code(
        creator: &signer, code: string::String, max_invites: u64
    ) acquires ReferralRegistry {
        assert_registry_exists();
        assert_code_not_exists(code);
        let creator_addr = signer::address_of(creator);
        assert_user_has_no_code(creator_addr, code);

        create_referral_code_internal(creator, code, max_invites);
        // check cannot duplcate users
        let now = timestamp::now_seconds();
        event::emit(
            ReferralCodeCreated {
                code: code,
                creator: creator_addr,
                timestamp: now,
                max_invites
            }
        );

        // init_code_object(creator, code, max_invites)
    }

    public(friend) fun assert_referral_code_available(
        code: string::String
    ) acquires ReferralRegistry {
        assert_registry_exists();
        assert!(is_code_available(code), ECODE_IS_NOT_AVAILABLE);
    }

    public(friend) fun increase_current_invites(
        invitee: address, code: string::String, quantity: u64
    ) acquires ReferralRegistry {
        assert_registry_exists();
        let key = create_referral_code_key(code);
        assert!(table::contains(&borrow_registry().codes, key), ECODE_NOT_EXISTS);

        let registry = borrow_registry_mut();
        let referral = table::borrow_mut(&mut registry.codes, key);

        // Check if max invites not reached
        assert!(referral.current_invites < referral.max_invites, EMAX_INVITES_REACHED);

        // Increment current invites
        referral.current_invites = referral.current_invites + 1;

        referral.current_sales = referral.current_sales + quantity;

        // Emit event
        let now = timestamp::now_seconds();
        event::emit(
            ReferralRoyaltyMarked {
                code: code,
                referrer: referral.creator,
                invitee,
                amount: quantity,
                timestamp: now
            }
        );
    }

    // === Public-View Functions ===

    // #[view]
    // public fun get_referral_code(object: Object<Referral>): string::String acquires Referral {
    //     assert_registry_exists();
    //     let referral = borrow_referral(object);

    //     referral.code
    // }

    // #[view]
    // public fun get_max_invites(object: Object<Referral>): u64 acquires Referral {
    //     assert_registry_exists();
    //     let referral = borrow_referral(object);

    //     referral.max_invites
    // }

    // #[view]
    // public fun get_referrer(code: string::String): option::Option<address> acquires ReferralRegistry {
    //     assert_registry_exists();
    //     let key = create_referral_code_key(code);
    //     if (table::contains(&borrow_registry().codes, key)) {
    //         let referral_code = table::borrow(&borrow_registry().codes, key);
    //         option::some(referral_code.creator)
    //     } else {
    //         option::none()
    //     }
    // }

    #[view]
    public fun is_code_available(code: string::String): bool acquires ReferralRegistry {
        if (!exists<ReferralRegistry>(@presale)) {
            return false
        };

        let key = create_referral_code_key(code);
        if (!table::contains(&borrow_registry().codes, key)) {
            return false
        };

        let referral_code = table::borrow(&borrow_registry().codes, key);
        referral_code.current_invites < referral_code.max_invites
    }

    #[view]
    public fun get_code_by_user(
        user: address
    ): option::Option<string::String> acquires ReferralRegistry {
        assert_registry_exists();
        let registry = borrow_registry();
        if (smart_table::contains(&registry.user_to_code, user)) {
            let code = smart_table::borrow(&registry.user_to_code, user);
            option::some(*code)
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_remaining_invites(code: string::String): u64 acquires ReferralRegistry {
        assert_registry_exists();
        let key = create_referral_code_key(code);
        if (table::contains(&borrow_registry().codes, key)) {
            let referral_code = table::borrow(&borrow_registry().codes, key);
            referral_code.max_invites - referral_code.current_invites
        } else { 0 }
    }

    #[view]
    public fun get_referral_stats(code: string::String): (u64, u64, u64) acquires ReferralRegistry {
        assert_registry_exists();
        let key = create_referral_code_key(code);
        if (table::contains(&borrow_registry().codes, key)) {
            let referral_code = table::borrow(&borrow_registry().codes, key);
            (
                referral_code.max_invites,
                referral_code.current_invites,
                referral_code.current_sales
            )
        } else {
            (0, 0, 0)
        }
    }

    // === Functions ===
    fun init_code_object(
        creator: &signer, code: string::String, max_invites: u64
    ): (signer, ConstructorRef) {
        let constructor_ref = object::create_object_from_account(creator);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        let referral_signer = object::generate_signer(&constructor_ref);

        let referral = Referral {
            code,
            creator: signer::address_of(creator),
            max_invites,
            delete_ref: object::generate_delete_ref(&constructor_ref),
            extend_ref: object::generate_extend_ref(&constructor_ref)
        };
        move_to(&referral_signer, referral);

        (referral_signer, constructor_ref)
    }

    fun create_referral_code_internal(
        creator: &signer, code: string::String, max_invites: u64
    ) acquires ReferralRegistry {
        let registry = borrow_registry_mut();
        let creator_addr = signer::address_of(creator);
        let referral_code = ReferralCode {
            code: code,
            creator: creator_addr,
            max_invites,
            current_invites: 0,
            current_sales: 0
        };
        let key = create_referral_code_key(code);
        table::add(&mut registry.codes, key, referral_code);
        smart_table::add(&mut registry.user_to_code, creator_addr, code);
    }

    // === Inline Functions ===
    inline fun borrow_referral(object: Object<Referral>): &Referral {
        let obj_addr = object::object_address(&object);
        assert!(exists<Referral>(obj_addr), ENO_CODE);
        borrow_global<Referral>(obj_addr)
    }

    inline fun create_referral_code_key(code: string::String): ReferralCodeKey {
        ReferralCodeKey { code: code }
    }

    inline fun borrow_registry_mut(): &mut ReferralRegistry {
        borrow_global_mut<ReferralRegistry>(@presale)
    }

    inline fun borrow_registry(): &ReferralRegistry {
        borrow_global<ReferralRegistry>(@presale)
    }

    inline fun assert_user_has_no_code(
        user: address, code: string::String
    ) {
        let registry = borrow_registry();
        assert!(!smart_table::contains(&registry.user_to_code, user), ECODE_EXISTS);
    }

    inline fun assert_code_not_exists(code: string::String) {

        let key = create_referral_code_key(code);
        assert!(!table::contains(&borrow_registry().codes, key), ECODE_EXISTS);
    }

    inline fun assert_registry_exists() {
        assert!(exists<ReferralRegistry>(@presale), EREGISTRY_NOT_EXISTS);
    }

    // == Tests ===
    #[test_only]
    use aptos_framework::coin;

    #[test_only]
    use aptos_framework::aptos_coin::{Self};

    #[test_only]
    use aptos_framework::aptos_coin::{AptosCoin};

    #[test_only]
    use aptos_framework::account::{Self, create_account_for_test};

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

    #[test(core = @0x1, sender = @presale, user = @0xB)]
    public fun test_create_referral_code_ok(
        core: &signer, sender: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, sender, user);

        init_referral_registry(sender);

        let code = string::utf8(b"TESTCODE");
        let max_invites = 5;

        create_referral_code(user, code, max_invites);

        let registry = borrow_registry();
        let user_code = registry.user_to_code.borrow(signer::address_of(user));
        let key = create_referral_code_key(*user_code);

        assert!(table::contains(&registry.codes, key), 0);

        let referral_code = table::borrow(&registry.codes, key);
        assert!(referral_code.creator == signer::address_of(user), 0);
        assert!(referral_code.max_invites == max_invites, 0);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(core = @0x1, sender = @presale, user = @0xB)]
    #[expected_failure(abort_code = ECODE_EXISTS, location = Self)]
    public fun test_create_duplicate_referral_code(
        core: &signer, sender: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, sender, user);

        init_referral_registry(sender);

        let code = string::utf8(b"DUPLICATE");
        let max_invites = 5;

        // Create first referral code
        create_referral_code(user, code, max_invites);

        // Try to create the same code again - should fail
        create_referral_code(user, code, max_invites);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(core = @0x1, user = @0xB)]
    #[expected_failure(abort_code = EREGISTRY_NOT_EXISTS, location = Self)]
    public fun test_create_referral_code_without_registry(
        core: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, user, user);

        // Don't initialize registry
        let code = string::utf8(b"NOREGISTRY");
        let max_invites = 5;

        // Try to create referral code without registry - should fail
        create_referral_code(user, code, max_invites);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // #[test(
    //     core = @0x1, sender = @presale, userA = @0xB, userB = @0xC
    // )]
    // #[expected_failure(abort_code = 327683, location = aptos_framework::object)]
    // public fun test_referral_object_cannot_transfer(
    //     core: &signer,
    //     sender: &signer,
    //     userA: &signer,
    //     userB: &signer
    // ) acquires ReferralRegistry {
    //     let (burn_cap, mint_cap) = init_module_for_test(core, sender, userA);

    //     init_referral_registry(sender);

    //     let code = string::utf8(b"NOTRANSFER");
    //     let max_invites = 3;
    //     let (referral_signer, constructor_ref) =
    //         create_referral_code(userA, code, max_invites);

    //     // let obj_addr = signer::address_of(&referral_signer);
    //     // let object = object::object_from_constructor_ref<ObjectCore>(&constructor_ref);

    //     // object::transfer(userA, object, signer::address_of(userB));

    //     coin::destroy_burn_cap(burn_cap);
    //     coin::destroy_mint_cap(mint_cap);
    // }

    #[test(core = @0x1, sender = @presale, user = @0xB)]
    public fun test_increase_current_invites_success(
        core: &signer, sender: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, sender, user);

        init_referral_registry(sender);

        let code = string::utf8(b"INCRSUCCESS");
        let max_invites = 2;

        create_referral_code(user, code, max_invites);

        // First invite
        increase_current_invites(signer::address_of(user), code, 10);

        // Second invite (should still succeed)
        increase_current_invites(signer::address_of(user), code, 5);

        // Check state
        let registry = borrow_registry();
        let key = create_referral_code_key(code);
        let referral_code = table::borrow(&registry.codes, key);
        assert!(referral_code.current_invites == 2, 0);
        assert!(referral_code.current_sales == 15, 0);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(core = @0x1, sender = @presale, user = @0xB)]
    #[expected_failure(abort_code = EMAX_INVITES_REACHED, location = Self)]
    public fun test_increase_current_invites_over_max_invites(
        core: &signer, sender: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, sender, user);

        init_referral_registry(sender);

        let code = string::utf8(b"INCRFAIL");
        let max_invites = 1;

        create_referral_code(user, code, max_invites);

        // First invite (should succeed)
        increase_current_invites(signer::address_of(user), code, 1);

        // Second invite (should fail)
        increase_current_invites(signer::address_of(user), code, 1);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(core = @0x1, sender = @presale, user = @0xB)]
    public fun test_get_referral_stats_ok(
        core: &signer, sender: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, sender, user);

        init_referral_registry(sender);

        let code = string::utf8(b"STATS123");
        let max_invites = 10;

        create_referral_code(user, code, max_invites);

        // Check initial stats
        let (max, current, sales) = get_referral_stats(code);
        assert!(max == 10, 0);
        assert!(current == 0, 1);
        assert!(sales == 0, 2);

        // Add some invites
        increase_current_invites(signer::address_of(user), code, 5);
        increase_current_invites(signer::address_of(user), code, 3);

        // Check updated stats
        let (max, current, sales) = get_referral_stats(code);
        assert!(max == 10, 3);
        assert!(current == 2, 4);
        assert!(sales == 8, 5);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(core = @0x1, sender = @presale, user = @0xB)]
    public fun test_get_referral_stats_nonexistent_code(
        core: &signer, sender: &signer, user: &signer
    ) acquires ReferralRegistry {
        let (burn_cap, mint_cap) = init_module_for_test(core, sender, user);

        init_referral_registry(sender);

        let code = string::utf8(b"NONEXISTENT");

        // Check stats for non-existent code
        let (max, current, sales) = get_referral_stats(code);
        assert!(max == 0, 0);
        assert!(current == 0, 1);
        assert!(sales == 0, 2);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
