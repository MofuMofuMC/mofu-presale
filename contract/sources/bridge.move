module bridge::bridge {
    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use std::signer;
    use aptos_std::ed25519::{Self};

    // use aptos_framework::resource_account;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event::{Self};
    use aptos_framework::object::{Self};
    use aptos_framework::ordered_map;

    use aptos_std::table::{Self, Table};
    use bridge::bridge_message::{Self, BridgeMessage, BridgeMessageKey};
    use bridge::mofu_nft::{Self, MofuToken};

    // ======== Constants ========
    // ======== Events ========

    #[event]
    struct CreateBridgeRecordEvent has drop, store {
        seq_num: u64,
        token_id: u256,
        source_addr: vector<u8>,
        target_addr: address
    }

    #[event]
    struct ClaimEvent has drop, store {
        token_id: u256,
        recipient: address
    }

    #[event]
    struct ValidatorAddedEvent has drop, store {
        validator_addr: vector<u8>
    }

    #[event]
    struct ValidatorRemovedEvent has drop, store {
        validator_addr: vector<u8>
    }

    // ======== Error codes ========

    const ENOT_AUTHORIZED: u64 = 1;
    const EINVALID_SIGNATURE: u64 = 2;
    const EINVALID_VALIDATOR: u64 = 3;
    const EVALIDATOR_ALREADY_EXISTS: u64 = 4;
    const EVALIDATOR_NOT_FOUND: u64 = 5;
    const EINVALID_VALIDATOR_ADDR: u64 = 6;
    const EINVALID_VALIDATOR_ADDR_LENGTH: u64 = 7;
    const EALREADY_CLAIMED: u64 = 8;
    const EINVALID_RECIPIENT: u64 = 9;
    const EINVALID_VALIDATOR_PK: u64 = 10;
    const EVALIDATOR_INDEX_OUT_OF_BOUNDS: u64 = 11;
    const ERECORD_ALREADY_EXISTS: u64 = 12;
    const EPAUSED: u64 = 13;
    const ETOKEN_NOT_FOUND: u64 = 14;

    // ======== Struct ========

    struct BridgeRecord has store {
        message: BridgeMessage,
        verified_signatures: Option<vector<vector<u8>>>,
        claimed: bool,
        recipient: address
    }

    struct BridgeRegistry has key {
        records: Table<BridgeMessageKey, BridgeRecord>,
        pending_claims: ordered_map::OrderedMap<u256, address>,
        claimed_tokens: vector<u256>,
        validators: vector<vector<u8>>,
        verified_signatures: vector<vector<u8>>,
        enabled: bool,
        admin_cap: SignerCapability
    }

    fun init_module(sender: &signer) {
        let (resource_signer, resource_cap) =
            account::create_resource_account(sender, b"nft");

        mofu_nft::create_mofu_collection(&resource_signer);

        move_to(
            sender,
            BridgeRegistry {
                admin_cap: resource_cap,
                claimed_tokens: vector::empty<u256>(),
                validators: vector::empty<vector<u8>>(),
                records: table::new(),
                verified_signatures: vector::empty<vector<u8>>(),
                enabled: true,
                pending_claims: ordered_map::new()
            }
        );
    }

    public entry fun premint(sender: &signer) acquires BridgeRegistry {
        assert_admin(sender); // Check admin authorization
        let registry = borrow_global_mut<BridgeRegistry>(@bridge);
        let resource_signer = account::create_signer_with_capability(&registry.admin_cap);

        for (i in 0..500) {
            let token_id = i as u256;
            let token_address = mofu_nft::mint_token(&resource_signer, token_id);

            registry.pending_claims.add(token_id, token_address);
        }
    }

    fun find_validator_index(validator_addr: vector<u8>): u64 acquires BridgeRegistry {
        let validators = get_validators_from_registry();
        let index = 0;

        for (i in 0..vector::length<vector<u8>>(&validators)) {
            let exist_validator_addr = vector::borrow(&validators, i);
            if (exist_validator_addr == &validator_addr) {
                index = i + 1;
                break;
            }
        };

        index
    }

    public entry fun add_validator(
        sender: &signer, validator_addr: vector<u8>
    ) acquires BridgeRegistry {
        assert_admin(sender); // Check admin authorization
        assert!(
            vector::length<u8>(&validator_addr) == 32, EINVALID_VALIDATOR_ADDR_LENGTH
        ); // Invalid validator address length
        let registry = borrow_global_mut<BridgeRegistry>(@bridge);

        vector::push_back(&mut registry.validators, validator_addr);
    }

    inline fun borrow_registry(): &BridgeRegistry acquires BridgeRegistry {
        borrow_global<BridgeRegistry>(@bridge)
    }

    inline fun borrow_registry_mut(): &mut BridgeRegistry acquires BridgeRegistry {
        borrow_global_mut<BridgeRegistry>(@bridge)
    }

    inline fun get_validator_from_registry(index: u64): vector<u8> acquires BridgeRegistry {
        let registry = borrow_global<BridgeRegistry>(@bridge);
        assert!(
            index < vector::length<vector<u8>>(&registry.validators),
            EVALIDATOR_INDEX_OUT_OF_BOUNDS
        ); // Index out of bounds

        *vector::borrow(&registry.validators, index)
    }

    public entry fun create_bridge_record(
        source_addr: vector<u8>,
        target_addr: address,
        token_id: u256,
        bridge_seq_num: u64,
        validator_index: u64,
        signature: vector<u8>
    ) acquires BridgeRegistry {
        let validator = get_validator_from_registry(validator_index);

        let message_hash =
            bridge_message::create_message_hash_internal(
                source_addr,
                target_addr,
                token_id,
                bridge_seq_num
            );

        let valid = verify_validator_signature_internal(
            validator, message_hash, signature
        );

        assert!(valid, EINVALID_SIGNATURE); // Signature verification failed

        let registry = borrow_global_mut<BridgeRegistry>(@bridge);
        let key = bridge_message::create_message_key(token_id);

        assert!(
            table::contains(&registry.records, key) == false,
            ERECORD_ALREADY_EXISTS
        );

        let record = BridgeRecord {
            message: bridge_message::create_message(
                bridge_seq_num,
                token_id,
                source_addr,
                target_addr
            ),
            verified_signatures: option::none(),
            claimed: false,
            recipient: target_addr
        };

        table::add(&mut registry.records, key, record);
        vector::push_back(&mut registry.verified_signatures, signature);

        event::emit(
            CreateBridgeRecordEvent {
                seq_num: bridge_seq_num,
                token_id: token_id,
                source_addr: source_addr,
                target_addr: target_addr
            }
        );
    }

    fun claim_internal(claimer: &signer, token_id: u256) acquires BridgeRegistry {
        let registry = borrow_registry_mut();
        asset_not_paused(registry);
        assert!(
            registry.pending_claims.contains(&token_id),
            error::not_found(ETOKEN_NOT_FOUND)
        ); // Not the recipient

        let key = bridge_message::create_message_key(token_id);
        let bridge_record = table::borrow_mut(&mut registry.records, key);
        let claimer_addr = signer::address_of(claimer);

        assert!(bridge_record.claimed == false, error::already_exists(EALREADY_CLAIMED)); // Already claimed
        assert!(
            bridge_record.recipient == claimer_addr,
            error::unavailable(EINVALID_RECIPIENT)
        ); // Not the recipient

        let token_address = registry.pending_claims.borrow(&token_id);
        let token_object = object::address_to_object<MofuToken>(*token_address);

        let resource_signer = account::create_signer_with_capability(&registry.admin_cap);

        object::transfer(&resource_signer, token_object, claimer_addr);
        registry.pending_claims.remove(&token_id);
        vector::push_back(&mut registry.claimed_tokens, token_id);

        bridge_record.claimed = true;
        event::emit(ClaimEvent { recipient: claimer_addr, token_id: token_id });
    }

    inline fun asset_not_paused(registry: &BridgeRegistry) {
        assert!(is_enabled(registry), error::invalid_state(EPAUSED))
    }

    public entry fun claim(claimer: &signer, token_id: u256) acquires BridgeRegistry {
        claim_internal(claimer, token_id);
    }

    inline fun assert_admin(sender: &signer) {
        let sender_address = signer::address_of(sender);
        assert!(sender_address == @admin_addr, error::permission_denied(ENOT_AUTHORIZED));
    }

    public entry fun remove_validator(
        sender: &signer, validator_addr: vector<u8>
    ) acquires BridgeRegistry {
        assert_admin(sender); // Check admin authorization

        let index = find_validator_index(validator_addr);
        assert!(index > 0, 3); // Validator does not exist

        let registry = borrow_global_mut<BridgeRegistry>(@bridge);
        vector::remove(&mut registry.validators, index - 1);
    }

    inline fun is_enabled(registry: &BridgeRegistry): bool {
        registry.enabled
    }

    #[view]
    public fun get_validators_from_registry(): vector<vector<u8>> acquires BridgeRegistry {
        let registry = borrow_global<BridgeRegistry>(@bridge);
        registry.validators
    }

    #[view]
    public fun has_enabled(): bool acquires BridgeRegistry {
        let registry = borrow_global<BridgeRegistry>(@bridge);
        is_enabled(registry)
    }

    #[view]
    public fun get_validator_count(): u64 acquires BridgeRegistry {
        let validators = get_validators_from_registry();
        vector::length(&validators)
    }

    #[view]
    public fun get_validator(index: u64): vector<u8> acquires BridgeRegistry {
        get_validator_from_registry(index)
    }

    /// Set if minting is enabled for this minting contract
    public entry fun set_enabled(caller: &signer, enabled: bool) acquires BridgeRegistry {
        let caller_address = signer::address_of(caller);
        assert!(caller_address == @admin_addr, error::permission_denied(ENOT_AUTHORIZED));
        let registry = borrow_global_mut<BridgeRegistry>(@bridge);
        registry.enabled = enabled;
    }

    fun verify_validator_signature_internal(
        validator_addr: vector<u8>, message: vector<u8>, signature_bytes: vector<u8>
    ): bool acquires BridgeRegistry {

        let index = find_validator_index(validator_addr);
        assert!(index > 0, EVALIDATOR_ALREADY_EXISTS); // Validator does not exist

        let option_pk = ed25519::new_validated_public_key_from_bytes(validator_addr);

        assert!(option::is_some(&option_pk), EINVALID_VALIDATOR_PK); // Invalid public key

        let pk = option::extract(&mut option_pk);

        bridge_message::verify_signature_internal(pk, message, signature_bytes)
    }

    // ======== Test ========

    #[test_only]
    use std::string;

    #[test_only]
    use aptos_token_objects::collection::{Self};

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = 851977)]
    fun test_claim_fails_when_token_unavailable(sender: &signer) acquires BridgeRegistry {
        // Init and prepare a bridge record without preminting tokens
        init_module(sender);
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        add_validator(sender, validator);

        premint(sender);
        // Create bridge record but don't premint
        create_bridge_record(
            b"1234567890abcdef1234567890abcdef12345678",
            @0xc697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e832,
            10,
            10,
            0,
            x"21d748f2569791e8587170934c4c402ebce7dc69ef6318c234035ea270c3d2565bb4db50470a0df48772945fe3ea7d5379487509ed99843176f588f7539bbd05"
        );

        // Try to claim without available token
        claim(sender, 10);
    }

    #[test(sender = @bridge, claimer = @0x33)]
    fun test_premint_success(sender: &signer) acquires BridgeRegistry {
        init_module(sender);
        premint(sender);

        let registry = borrow_registry();

        let resource_signer = account::create_signer_with_capability(
            &registry.admin_cap
        );
        let collection_name = string::utf8(b"Mofu Mofu Music Caravan");
        let collection_address =
            collection::create_collection_address(
                &signer::address_of(&resource_signer), &collection_name
            );
        let collection =
            object::address_to_object<collection::Collection>(collection_address);

        assert!(collection::count(collection) == option::some(500), 0);

        let registry = borrow_global<BridgeRegistry>(@bridge);

        let pending_claims = registry.pending_claims;
        let pending_claims_length = pending_claims.length();
        assert!(pending_claims_length == 500, 0);
    }

    #[test(admin = @bridge, sender = @0x1A)]
    #[expected_failure(abort_code = 327681)]
    fun test_premint_fails_with_user(admin: &signer, sender: &signer) acquires BridgeRegistry {
        init_module(admin);
        premint(sender);
    }

    #[test(sender = @bridge)]
    fun test_validator_management_success(sender: &signer) acquires BridgeRegistry {
        // let sender_addr = signer::address_of(sender);
        // Set up test environment
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        // Initialize module with admin
        init_module(sender);

        // Add validator
        add_validator(sender, validator);

        // Check if validator exists
        let validator_exists = find_validator_index(validator);
        // debug::print(&validator_exists);
        assert!(validator_exists > 0, 0);

        // // Remove validator
        remove_validator(sender, validator);

        // // Check if validator was removed
        let validator_count = get_validator_count();
        assert!(validator_count == 0, 0);
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = 0x50001)]
    fun test_add_validator_fails_with_normal_user(sender: &signer) acquires BridgeRegistry {
        let mock_user = account::create_signer_for_test(@0x11);
        // Set up test environment
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        // Initialize module with admin
        init_module(sender);

        // Add validator
        add_validator(&mock_user, validator);
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = 0x50001)]
    fun test_remove_validator_fails_with_normal_user(sender: &signer) acquires BridgeRegistry {
        let mock_user = account::create_signer_for_test(@0x11);
        // Set up test environment
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        // Initialize module with admin
        init_module(sender);

        // Add validator
        add_validator(sender, validator);

        // // // Remove validator
        remove_validator(&mock_user, validator);

    }

    #[test(sender = @bridge)]
    fun test_create_bridge_record_success(sender: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0xc697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e832;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            x"2831323334353637383930616263646566313233343536373839306162636465663132333435363738c697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e8320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"21d748f2569791e8587170934c4c402ebce7dc69ef6318c234035ea270c3d2565bb4db50470a0df48772945fe3ea7d5379487509ed99843176f588f7539bbd05";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );
        // Add validator

        let valid =
            verify_validator_signature_internal(
                validator_addr,
                message,
                signature
                // signer::address_of(sender)
            );

        let registry = borrow_global<BridgeRegistry>(@bridge);

        assert!(vector::length(&registry.verified_signatures) == 1, 0); // Signature not verified
        assert!(valid, EINVALID_SIGNATURE); // Signature verification failed
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = EVALIDATOR_INDEX_OUT_OF_BOUNDS)]
    fun test_create_bridge_record_fails_with_invalid_validator(
        sender: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0xc697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e832;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        // let message =
        //     x"2831323334353637383930616263646566313233343536373839306162636465663132333435363738c697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e8320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"21d748f2569791e8587170934c4c402ebce7dc69ef6318c234035ea270c3d2565bb4db50470a0df48772945fe3ea7d5379487509ed99843176f588f7539bbd05";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            1,
            signature
        );
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = ERECORD_ALREADY_EXISTS)]
    fun test_create_bridge_record_fails_with_duplicate(sender: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0xc697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e832;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        // let message =
        //     x"2831323334353637383930616263646566313233343536373839306162636465663132333435363738c697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e8320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"21d748f2569791e8587170934c4c402ebce7dc69ef6318c234035ea270c3d2565bb4db50470a0df48772945fe3ea7d5379487509ed99843176f588f7539bbd05";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );
        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = EINVALID_SIGNATURE)]
    fun test_create_bridge_record_fails_with_invalid_signature(
        sender: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0xc697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e832;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        // let message =
        //     x"2831323334353637383930616263646566313233343536373839306162636465663132333435363738c697791f11639b6e4703064e6050d2867e0a46b2ad33d7f4fb7b1dd59fd6e8320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"20d748f2569791e8587170934c4c402ebce7dc69ef6318c234035ea270c3d2565bb4db50470a0df48772945fe3ea7d5379487509ed99843176f588f7539bbd05";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );
    }

    #[
        test(
            sender = @bridge,
            user = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 393230)]
    fun test_claim_fails_with_duplicate(sender: &signer, user: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let signature =
            x"e8490782e10de58aaf46a1f35c1dd1d027eb20e50402210af3b52578a1f7b31510cb408d9fa5d8cef6fa347a037f515d7b8eb72072c0218a5782e60d238b9d0c";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );

        premint(sender);
        claim(user, token_id);

        let registry = borrow_global<BridgeRegistry>(@bridge);
        let key = bridge_message::create_message_key(token_id);

        let bridge_record = table::borrow(&registry.records, key);
        assert!(bridge_record.claimed == true, 0); // Already claimed
        assert!(bridge_record.recipient == signer::address_of(user), 0); // Not the recipient
        claim(user, token_id);
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = 196621)]
    fun test_claim_fails_with_paused(sender: &signer) acquires BridgeRegistry {
        // let sender_addr = signer::address_of(sender);
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let signature =
            x"e8490782e10de58aaf46a1f35c1dd1d027eb20e50402210af3b52578a1f7b31510cb408d9fa5d8cef6fa347a037f515d7b8eb72072c0218a5782e60d238b9d0c";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );

        set_enabled(sender, false);

        claim(sender, token_id);
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = 0x50001)]
    fun test_set_enabled_fails_with_normal_user(sender: &signer) acquires BridgeRegistry {
        let mock_user = account::create_signer_for_test(@0x11);
        init_module(sender);

        // Try to pause bridge with non-admin
        set_enabled(&mock_user, false);
    }

    #[test(sender = @bridge)]
    #[expected_failure(abort_code = 851977)]
    fun test_claim_fails_with_invalid_receipent(sender: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let signature =
            x"e8490782e10de58aaf46a1f35c1dd1d027eb20e50402210af3b52578a1f7b31510cb408d9fa5d8cef6fa347a037f515d7b8eb72072c0218a5782e60d238b9d0c";
        init_module(sender);

        add_validator(sender, validator_addr);

        let mock_user1 = account::create_signer_for_test(@0x11);
        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );

        premint(sender);

        claim(&mock_user1, token_id);
    }

    #[
        test(
            sender = @bridge,
            user = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    fun test_claim_success(sender: &signer, user: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let signature =
            x"e8490782e10de58aaf46a1f35c1dd1d027eb20e50402210af3b52578a1f7b31510cb408d9fa5d8cef6fa347a037f515d7b8eb72072c0218a5782e60d238b9d0c";
        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            10,
            0,
            signature
        );

        premint(sender);

        claim(user, token_id);

        let registry = borrow_global<BridgeRegistry>(@bridge);
        let key = bridge_message::create_message_key(token_id);
        let bridge_record = table::borrow(&registry.records, key);

        assert!(bridge_record.claimed == true, 0); // Already claimed
        assert!(bridge_record.recipient == signer::address_of(user), 0); // Not the recipient
        assert!(registry.pending_claims.contains(&token_id) == false, 0); //
        assert!(vector::length(&registry.claimed_tokens) == 1, 0); // Not the recipient
        assert!(vector::contains(&registry.claimed_tokens, &token_id) == true, 0); // Not the recipient
        assert!(registry.pending_claims.length() == 499, 0); // Not the recipient
        assert!(vector::length(&registry.verified_signatures) == 1, 0); // Signature not verified
    }

    #[test(sender = @bridge)]
    fun test_valid_signature_success(sender: &signer) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            b"283132333435363738393061626364656631323334353637383930616263646566313233343536373840633639373739316631313633396236653437303330363465363035306432383637653061343662326164333364376634666237623164643539666436653833320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"3896ac617999460c3e9014bf85b48b6d8db25c0817b78e4a502785a30878a19d6e444bba506e533dc96d4d44197b71e6733ad4e7b59418c936bad6b111c78303";
        init_module(sender);

        // Add validator
        add_validator(sender, validator_addr);

        let is_valid =
            verify_validator_signature_internal(
                validator_addr,
                message,
                signature
                // signer::address_of(sender)
            );

        assert!(is_valid, EINVALID_SIGNATURE); // Signature verification failed
    }

    #[test(sender = @bridge)]
    // #[expected_failure(abort_code=EINVALID_SIGNATURE)]
    fun test_invalid_signature_success(sender: &signer) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            b"283132333435363738393061626364656631323334353637383930616263646566313233343536373840633639373739316631313633396236653437303330363465363035306432383637653061343662326164333364376634666237623164643539666436653833320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"2096ac617999460c3e9014bf85b48b6d8db25c0817b78e4a502785a30878a19d6e444bba506e533dc96d4d44197b71e6733ad4e7b59418c936bad6b111c78303";
        init_module(sender);

        // Add validator
        add_validator(sender, validator_addr);

        let is_valid =
            verify_validator_signature_internal(
                validator_addr,
                message,
                signature
                // signer::address_of(sender)
            );
        assert!(is_valid == false, 0);
    }

    #[test(sender = @bridge, user = @0x123)]
    #[expected_failure(abort_code = 327681)]
    fun test_add_validator_fails_with_user(
        sender: &signer, user: &signer
    ) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(sender);

        // Add validator
        add_validator(user, validator_addr);
    }

    #[test(sender = @bridge, user = @0x123)]
    #[expected_failure(abort_code = 327681)]
    fun test_remove_validator_fails_with_user(
        sender: &signer, user: &signer
    ) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(sender);

        // Add validator
        add_validator(sender, validator_addr);
        // Remove validator
        remove_validator(user, validator_addr);
    }
}
